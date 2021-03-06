---
title: Part One - Infrastructure with SDL2
has-toc: yes
date: 2016-02-16
description: Creating the infrastructure for Odin using SDL2
---

Intro
================================================================================
This is part of a series where we'll be writing a roguelike using FRP 
and Haskell. This article is about setting up the main loop and rendering.  
This version of the article uses SDL2 for the gelatin backend and only 
addresses the differences between GLFW and SDL2. Please see [part one][part-one] 
for thorough tutorial.  

Get the Code
--------------------------------------------------------------------------------
This is a Literate Haskell file which can be downloaded from the 
[github repo][odin]. To build, run `stack build` from the project
directory. [Go here](http://docs.haskellstack.org/en/stable/README.html) 
for help with `stack`.

Main
================================================================================

> -- |
> --   Module:     Main
> --   Copyright:  (c) 2015 Schell Scivally
> --   License:    MIT
> --
> module Main where
> import Control.Varying

For the SDL2 version our imports are identical except we switch out the backend.
You can see that `SDL` introduces some conflicts with `Control.Varying` that we
need to work around using qualified imports and hiding.

> import Gelatin.SDL2 hiding (Event, time)
> import qualified SDL

Everything else here is business as usual :)

> import Control.Concurrent
> import Control.Concurrent.Async
> import Control.Concurrent.STM.TVar
> import Control.Monad.STM
> import Control.Monad.Trans.Writer.Strict
> import Control.Monad
> import Data.Time.Clock
> import System.Exit
> import Linear.Affine (Point(..))

Types
================================================================================
The only changes needed here are a couple additions to our `UserInput`. We have
to encode a bit more window handling for SDL2, which is neither good nor bad.
On the good side it makes window handling explicit instead of GLFW's convenient
but mysterious `windowShouldClose` function.

> data UserInput = InputUnknown String
>                | InputTime Float
>                | InputCursor Float Float
>                | InputWindowSize Int Int
>                | InputWindowClosed
>                deriving (Show)

All other type level stuff stays the same for our refactor.

> data OutputEvent = OutputEventUnknown String
>                  | OutputNeedsUpdate
>                  deriving (Ord, Eq)
>
> type Effect = Writer [OutputEvent]
> type Pic = Picture ()
> type Network = VarT Effect UserInput Pic
> data AppData = AppData { appNetwork :: Network
>                        , appCache   :: Cache IO Transform
>                        , appEvents  :: [UserInput]
>                        , appUTC     :: UTCTime
>                        }

The Network
================================================================================
Here you'll see there are absolutely no updates to our network.  This is great! 
We've organized our code so that the network only depends on game events and in 
this kind of situation we get to reap those benefits ... by doing nothing at 
all. Score one for FRP and Haskell in general.

> cursorMoved :: (Applicative m, Monad m) => VarT m UserInput (Event (V2 Float))
> cursorMoved = var f ~> onJust
>     where f (InputCursor x y) = Just $ V2 x y
>           f _ = Nothing
>
> cursorPosition :: (Applicative m, Monad m) => VarT m UserInput (V2 Float)
> cursorPosition = cursorMoved ~> foldStream (\_ v -> v) (-1)
>
> timeUpdated :: (Applicative m, Monad m) => VarT m UserInput (Event Float)
> timeUpdated = var f ~> onJust
>     where f (InputTime t) = Just t
>           f _ = Nothing
>
> deltas :: (Applicative m, Monad m) => VarT m UserInput Float
> deltas = 0 `orE` timeUpdated
>
> requestUpdate :: VarT Effect a a
> requestUpdate = varM $ \input -> do
>     tell [OutputNeedsUpdate] 
>     return input
>
> time :: VarT Effect UserInput Float
> time = deltas ~> requestUpdate
>
> easeInOutSpline :: (Applicative m, Monad m) 
>                 => Float -> SplineT Float Float m Float
> easeInOutSpline t = do
>     halfway <- tween easeInExpo 1 0 $ t/2
>     tween linear halfway 1 $ t/2
>
> easeInOutExpo :: (Applicative m, Monad m) => Float -> VarT m Float Float 
> easeInOutExpo = outputStream 1 . easeInOutSpline
>
> multSequence :: Float -> SplineT UserInput Float Effect Float
> multSequence t = do
>     (val,_) <- (time ~> easeInOutExpo t) `untilEvent` (time ~> after t)
>     return val
>
> multOverTime :: Float -> VarT Effect UserInput Float
> multOverTime = outputStream 0 . multSequence 
>
> picture :: V2 Float -> Float -> Float -> Float -> Float -> Pic
> picture cursor s r g b = 
>     move cursor $ scale (V2 s s) $ withFill (solid $ V4 r g b 1)
>         $ circle 100 
>
> network :: VarT Effect UserInput Pic
> network = picture <$> cursorPosition 
>                   <*> multOverTime 3
>                   <*> multOverTime 1 <*> multOverTime 2 <*> multOverTime 3

Our Game Loop
================================================================================
Most of the changes happen in our main loop. Window management is a bit more
complicated, but not bad. Most of our setup is the same.

> main :: IO ()
> main = do
>     (rez,window) <- startupSDL2Backend 800 600 "Odin Part One - SDL2" True
>     setWindowPosition window $ Absolute $ P $ V2 400 400
>     t0   <- getCurrentTime
>     tvar <- atomically $ newTVar AppData{ appNetwork = network 
>                                         , appCache   = mempty
>                                         , appEvents  = []
>                                         , appUTC     = t0
>                                         }
>     let push input = atomically $ modifyTVar' tvar $ \app -> 
>                          app{ appEvents = appEvents app ++ [input] }

One expected difference is in how SDL2 handles input. GLFW allows you to set a
callback and then waitOdin for events to come in, keeping you from having to poll. 
GLFW could be polling under the hood, but with SDL2 that polling is explicit. 

Instead of using callbacks we'll write a function that handles our special 
input cases or simply `push`s our input. The special case to handle is when 
the window manager requests that the window should close.

>         addInput InputWindowClosed = exitSuccess

All other input can simply be pushed into our queue.

>         addInput input = push input

Instead of callbacks we need a function that unwraps SDL events and turns them 
into our game events. You'll see here that SDL gives us much more information 
than GLFW. Most of this function is unwrapping the event. We return a list so 
we can `concatMap` this function over all of SDL's events in one fell swoop.

>         fevent (SDL.Event _ 
>                 (MouseMotionEvent 
>                  (MouseMotionEventData _ _ _ (P (V2 x y)) _))) = 
>             [InputCursor (fromIntegral x) (fromIntegral y)]
>         fevent (SDL.Event _ 
>                 (WindowResizedEvent 
>                  (WindowResizedEventData _ (V2 w h)))) =
>             [InputWindowSize (fromIntegral w) (fromIntegral h)]
>         fevent (SDL.Event _ 
>                 (WindowClosedEvent 
>                  (WindowClosedEventData _))) =
>             [InputWindowClosed]
>         fevent _ = []

Now we write our own version of GLFW's `waitOdinEvents` function. This function 
reads our app's event queue - if any events have been added from any other 
threads (like a timer/render request thread) it will exit. If there are no 
events in total we should delay for ten millis and then loop. In this way we
can "put the main thread to sleep" and defer rendering until something happens. 
Not quite (we're still running the thread and polling) - but good enough. In 
both cases we poll for SDL events and run `addInput` over any newly received 
events. 

>         waitOdin = do
>             pastEvents  <- appEvents <$> readTVarIO tvar
>             inputEvents <- pollEvents
>             let newEvents = concatMap fevent inputEvents
>                 allEvents = pastEvents ++ newEvents
>             -- only add new events since past events have already been added
>             mapM_ addInput newEvents 
>             -- exit if there are any events, else recurse and poll again
>             when (null allEvents) $ do threadDelay 10 
>                                        waitOdin

Our stepOdin function is near identical to [part one][part-one] but we need to
swap `renderWithGLFW` with `renderWithSDL2`. 

>         stepOdin = do  
>             t <- getCurrentTime
>             putStrLn $ "stepOdinping " ++ show t
>             AppData net cache events lastUTC <- readTVarIO tvar
>             let dt = max oneFrame $ realToFrac $ diffUTCTime t lastUTC 
>                 ev = InputTime dt 
>                 ((pic, nextNet), outs) = runWriter $ stepMany events ev net 
>             newCache <- renderWithSDL2 window rez cache pic
>             atomically $ writeTVar tvar $ AppData nextNet newCache [] t
>             let needsUpdate = OutputNeedsUpdate `elem` outs
>                 requests = filter (/= OutputNeedsUpdate) outs 
>             mapM_ applyOutput requests 
>             when needsUpdate $ applyOutput OutputNeedsUpdate

>         oneFrame = 1/30 

In `applyOutput` we have to push an event in order to get `waitOdin` to find a 
new event in its queue. This will cause `waitOdin` to break and then `loop` will 
`stepOdin`.  We can use a simple `InputUnknown` as the event.

>         applyOutput OutputNeedsUpdate = void $ async $ do 
>             threadDelay $ round (oneFrame * 1000)
>             push $ InputUnknown "wake up" 
>         applyOutput _ = return ()

Then we stick our waitOdin function in place of GLFW's `waitOdinEvents`.

>         loop = stepOdin >> waitOdin >> loop
>     loop

Conclusion
--------------------------------------------------------------------------------
To recap, we updated our `UserInput` type, made slight changes to 
rendering and switched out the way we poll and add input events. What changed 
from a player perspective? Hopefully nothing! If you ran the two programs side
by side you would notice some differences. The first is that the GLFW version
has nicer edges on our circle. This comes from the fact that I'm not quite sure
yet how to query the framebuffer size in SDL, so my SDL backend for gelatin 
(which provides `ctxFramebufferSize`) just returns the window size. This is 
fine unless you're on a retina or 4k screen. Another difference is that we've
lost the ability to quit with Command+Q or Ctrl+Q. Fixing that is easy enough
and we'll fix it later in the series. 

All in all this refactor ended up being pretty easy. This is one of the strong 
points of Haskell. We just swapped out the entire windowing system and OpenGL 
context underneath our app - in under an hour. Truth be told, it took me a 
bit longer to research the SDL API, write the gelatin backend and to write the 
article but it was still an insignificant amount of time. Another major plus is
the total absence of fear during refactoring. At no point was I afraid I would
edit myself into a corner and have to `git stash; git drop` my changes and 
restart. That happens to me sometimes in lesser typed languages, but Haskell's
type system is a real friend.

Comments
--------------------------------------------------------------------------------
Please comment at [HN](https://news.ycombinator.com/item?id=11112599) 
or [Reddit](https://www.reddit.com/r/haskell/comments/4647er/refactoring_our_haskell_frp_from_glfw_to_sdl2/)

[1]: http://hackage.haskell.org/package/varying
[2]: http://github.com/schell/gelatin/tree/master/gelatin-picture
[3]: http://github.com/schell/gelatin/tree/master/gelatin-glfw
[4]: http://hackage.haskell.org/package/netwire
[5]: http://hackage.haskell.org/package/renderable

[part-one]: /series/odin/part-one
[odin]: https://github.com/schell/odin
[fonty]: http://hackage.haskell.org/package/FontyFruity
[linear]: http://hackage.haskell.org/package/linear
[glfw-b]: http://hackage.haskell.org/package/GLFW-b
[varying core]: http://hackage.haskell.org/package/varying/docs/Control-Varying-Core.html
[varying constructors]: http://hackage.haskell.org/package/varying/docs/Control-Varying-Core.html#g:1
