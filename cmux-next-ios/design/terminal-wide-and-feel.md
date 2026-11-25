# iOS terminal: right size first, landscape, sideways scroll, smooth scroll, normal long-press

Leo, 2026-11-23 17:43-18:03Z (paraphrased politely where he swore):

> im sometimes seeing these 118x69 load ins which are wide... then it properly goes.
> actually, on terminal correctness, why do we not have a horizontal mode? this is glaringly obvious [and] should've been done from day 1 of making the app.
> in the same vein, me scrolling to the right on an extra wide ghostty terminal output... does nothing. ... an extra wide table... just doesnt even work right now. didnt work before either. so we necessarily need logic for you to be able to like "horizontally scroll" ... being able to flip [it] horizontally and actually have a dedicated view would help too
> we should also be able to smooth out the jaggedness of scroll that we have in claude in terminal vs in regular shell terminal. latter feels smoother for some reason. so we need that tech. on ios.
> for ios, holding shouldnt raise the whole bubble of a chunk of text being selected. just hold and it should highlight text as normal then you select some bits etc ... normal behaviour. there was never a reason for hold to immediately select a chunk.

## The five pieces

Code lives in `cmux-next-ios/` on `feat-cmux-next` (the classic `ios/` app is retired). Each lands as its own PR so one stuck piece does not hold the others.

1. **No 118x69 flash.** The first frame uses the phone's grid. Find who sends the desktop or cached
   size first (presence sends `fittingGrid` before layout, the Mac's grid echo, a cached size) and
   make the first paint wait for the phone's size or start from it.
2. **Landscape.** Info.plist already lists both landscape orientations; find what pins portrait
   (scene, root controller, SwiftUI host) and let the terminal and the app rotate, with the grid
   resized to the wider width on rotation.
3. **Sideways scroll.** Output wider than the screen pans sideways instead of wrapping away.
   Variants shown in a gallery: (a) pan with axis lock, (b) a full-screen "wide output" view,
   (c) both, landscape opening the wide view. One is picked and built.
4. **Smooth scroll.** Measure frame times scrolling a Claude Code TUI pane and a plain shell pane,
   find why the TUI is jagged (alt-screen full redraws, row-snapped scroll, update cadence) and
   make it pixel-smooth at 120 Hz. Numbers before and after from one harness.
5. **Normal long-press.** Holding places a native text selection at the word with standard
   handles; it never selects a whole bubble or block. Every long-press in the app is audited for
   the same mistake.

Grid and selection logic shared with the Mac goes in Rust; views stay in Swift.
