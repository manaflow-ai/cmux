# Jump-to-bottom button: flash on a downward swipe

Branch `feat-cnx-ios-arrow`, 2026-10-13. This responds to a user recording from a real iPhone (production build
`094f3cd9`/`e039561f`): "when I swipe down arbitrarily, an arrow down button appears momentarily in a random place."

## The recording

`swipe-arrow.mp4` is 2.1 s at 120 fps (1320 x 2868). It was split into 60 fps frames and read frame by frame.

- **Screen:** an agent chat workspace tab ("New chat", Agent, workspace-1). The tab is empty: "What should Agent do?",
  with the "Agent hasn't started in this tab yet" notice above the composer. The keyboard is down.
- **What appears:** the glass jump-to-bottom circle (`arrow.down`). It appears while the finger pulls the empty
  transcript down, sitting over the notice and then over the composer's top edge. It drifts down and sideways as the
  stack re-lays out around it (from x = 660 px to 715 px, y moved about 100 px), then fades when the rubber band
  settles. This happened on each of the three pulls in the clip, at about 0.5 s each.

## Root cause

1. **Visibility counted the rubber band.** `ChatTranscriptController.scrollViewDidScroll` showed the button when
   `bottomOffset.y - contentOffset.y > 80`. In an empty or short chat the bottom offset equals the top offset.
   Pulling down moves `contentOffset.y` above the top (rubber band), so a pull of 81 pt read as "81 pt from the
   bottom" and showed the button until the bounce came back. There was no hysteresis either: a value hovering at
   80 pt toggled it every frame.
2. **Its place was not fixed.** In a workspace tab the circle was the first row of the TabsKit accessory's
   `VStack`. Showing it grew the accessory by 48 pt, so the composer stack re-laid out around it while it scaled in.
   That is the drift in the recording. In the pushed chat its hosting view sized itself from its content (8 x 8 pt
   when hidden, 44 x 44 pt when shown), so a layout pass inside a keyboard animation could animate it from the old
   frame.

The terminal had the same class of bug: `atBottom` used the raw offset, so pulling a short scrollback past the top
showed its scroll-to-bottom button.

## Fix

- `CmuxMobileDesign/JumpToBottom.swift`: `JumpToBottomVisibility`, one rule for every transcript.
  - The distance is measured from the offset clamped to `-contentInset.top ... bottomOffset`, so neither rubber band
    counts. An empty or short chat can never show the button.
  - Hysteresis: it shows past 120 pt and hides within 48 pt.
  - While the finger is pulling a docked keyboard down (an interactive dismissal), it never appears. It can still
    hide.
- `ChatTranscriptController`
  - It uses the rule in `scrollViewDidScroll` and after every inset pass. An empty chat resets it to hidden.
  - "Keyboard dragging" means three things hold: the scroll view is tracking, a docked keyboard is up (from the
    layout guide, or from the notified frame on the iOS 27 fallback path), and the finger has reached the stack's
    top. That is where UIKit hands the drag to the keyboard (`keyboardDismissPadding`).
  - The jump circle is now the controller's in both placements, the pushed chat and the workspace tab. Its host is
    a fixed 44 x 44 pt, centered, with its bottom 4 pt above the stack's top (`dockGuide`). The circle scales in
    place from its first frame, and showing it no longer changes the composer stack's height.
- `AgentChatBottomStack` no longer contains the circle, and the `showsJump` parameter is removed.
- `TerminalViewController` drives its scroll-to-bottom button with the same rule.
- The other screens were checked. The Feed, Chief (`CmuxConversation`, whose catch-up control is separate), and
  artifact previews have no jump-to-bottom control.

## Unit test (red, then green)

`CmuxMobileKit/Tests/CmuxMobileAgentChatTests/JumpToBottomTests.swift`, run with `swift test --filter JumpToBottom` (macOS).

- **Red:** commit `9a55ea05b397` adds the tests against the old rule (`distance > 80`, raw offset). 5 of 7 fail:
  `emptyChatPulledDownStaysHidden` (32 issues), `shortChatPulledDownStaysHidden` (38),
  `hysteresisKeepsItSteadyNearTheThreshold` (7), `showsOnlyPastTheShowDistance`, and
  `keyboardDragDismissNeverShowsIt`.
- **Green:** after the fix, all 8 tests in 2 suites pass. A state test was added that carries the value across
  frames.

## Simulator evidence

Two headless iPhone 17 Pro simulators were used: `cmux-mobile-arw-ios26` (iOS 26.5) and `cmux-mobile-arw-ios27` (iOS 27.0). The
build was Debug, from `verify/build.sh`, with `CMUX_MOBILE_MOCK_AUTH=1`, the software keyboard and dark appearance.
Simulator.app was never opened.

`verify/record-jump.sh <udid> <dir> <label> <demo> [up]` opens a screen with a DEBUG demo and takes the keyboard
down with an interactive transcript drag. While `simctl io recordVideo` records, it swipes the transcript down three
times with real AXe HID touches:

1. A 0.25 s flick of 300 pt.
2. A 0.9 s pull of 400 pt.
3. An off-centre 0.35 s pull of 220 pt.

`-cmux-mobile-kbd-trace` writes one line per display frame. Each line includes the following fields:

- `jump`: the button's state.
- `jumpFrame`: the host's presentation frame.
- `minOffset` and `maxOffset`.
- `kbdrag`: whether a keyboard drag is in progress.

The evidence is git-ignored, in `verify/evidence/jump/{red,green}/`. Each run has an `.mp4`, `-frames/` (every
recorded frame), `-sheet.png` (10 fps strip of the lower half), and, for green runs, `.trace.txt`.

| Run | Before (production code) | After |
| --- | --- | --- |
| iOS 26.5, empty workspace tab (`kbd-empty`) | The circle flashes above the composer during a pull (`red/ios26-tab-empty-sheet.png`, last row) | `jump=1` in 0 of 2213 traced frames; 220 tracking frames, pulled to offset -795 (172 pt past the top) |
| iOS 27.0, empty workspace tab | Not caught at 10 fps sampling | `jump=1` in 0 of 1443 frames; pulled 221 pt past the top |
| iOS 26.5, empty pushed chat (`kbd-chat-empty`) | — | `jump=1` in 0 of 1397 frames |
| iOS 27.0, empty pushed chat | — | `jump=1` in 0 of 1303 frames |
| iOS 26.5, long workspace tab chat (`kbd-tab`), a real scroll up | — | Over 3025 traced frames the button stays hidden until the real scroll first reaches about 120 pt from the bottom (it turns on at t = 17.04 s, at a traced distance of 118.7 pt; the trace reads presentation values, one frame behind the model). It then stays on for 2181 frames, while the reader stays scrolled up. The host is 44 x 44 at x = 179, centred on the 402 pt screen. Its bottom is 4 pt above the stack in every frame where it shows (y = 631, `dockTop` 679), so it never flies in. It moved, from y = 583 to 631, only while hidden, as the composer collapsed at load |

## Open items

- During this run the host ran out of process slots, and afterwards it was limited to one simulator. Because of that,
  these runs were not recorded:
  - the long-chat runs on iOS 27;
  - the pushed long chat;
  - a keyboard-up drag-dismiss on a long chat.

  The `kbdrag` path is covered by the unit test and the trace field, but there is no recording of it.
- These runs used the app's DEBUG mock sessions. The bug is client-side scroll geometry and needs no Mac. A
  confirmation against a real cmux-next Mac app build is still to do.
- The fix was not verified on a real device; no real-phone verification was requested.
