# Polish pass: verification

Branch `feat-cnx-ios-polish`, 2026-10-12/13. Simulators (headless, own):
`cmux-mobile-pol-ios26` (iPhone 17 Pro, iOS 26.5) and `cmux-mobile-pol-ios27` (iPhone 17 Pro,
iOS 27.0). Xcode 27.0, mock auth. Evidence is git-ignored, in
`verify/evidence/2026-10-13/polish/` (recordings, `*.timeline.txt`,
`*.keyboard.txt`, `frames/`, `sheets/`, `ref/`).

Owned by other agents since mid-pass (not edited after that point): sign-in
screens, toggle tint, workspace creation, Chief presentation, navigation
structure and the photo picker.

## 1. Terminal inside workspace tabs (embedded chrome)

`GhosttyTerminalTabContent` used to put the whole `TerminalScreen` (its own
navigation toolbar and keyboard-pinned stack) inside a TabsKit page, which
stacked two sets of chrome. Now:

- `TerminalViewController` has a `TerminalChrome`: `.standalone`
  (`TerminalScreen`, unchanged) or `.embedded` (a workspace tab).
- Embedded: TabsKit owns the status bar area and the floating toolbar.
  The controller gets TabsKit's insets (`setEmbeddedInsets`). The key bar
  and composer rest where TabsKit puts a tab accessory (composer bottom 8 pt
  above the toolbar capsule) and ride the keyboard from there. They stay in
  the controller rather than in TabsKit's SwiftUI accessory row, so the TUI
  clip, the scroll insets and the stack are solved in one Auto Layout pass
  inside the keyboard's animation (`keyboardLayoutGuide`, no notification
  driven constraint changes). TUI mode: the grid's bottom is pinned to the
  composer, its top clipped under the status bar (hard edge).
- Non-TUI scrollback runs under the status bar and the composer with soft
  edges (`UIScrollEdgeElementContainerInteraction` on a status bar strip and
  on the stack). iOS 26 draws no top effect for a bare container, so a
  gradient scrim stands in there.
- Title and tab switching are TabsKit's (capsule title, grid). The page menu
  gains the terminal's actions: Show/Hide Keyboard, Files and Links, Paste,
  Send Ctrl-C, Clear, Scroll to Bottom, then Copy Directory, All Workspaces,
  Close Tab (`TerminalTabContent.actions`). The key bar keeps its hide key.
- Files and Links is presented by the controller (UIKit sheet, medium and
  large detents).
- One `TerminalTabHost` (model + controller) per tab, kept while the tab
  exists: the surface and scrollback survive tab switches (verified: switch
  to the agent tab and back, scrollback intact). Closed tabs release theirs.
- Grid card: a snapshot of the page (`drawHierarchy`, render-server copy, so
  the Metal surface is included), taken when the grid opens and when the
  page leaves. No second Ghostty surface.

### Keyboard tracking, frame by frame (`ws-terminal` demo)

Every recorded frame of each transition, `analyze_keyboard.sh` with
`STACK_FLOOR=790` (the stack scan starts above TabsKit's toolbar). Frames
where the keyboard's top is behind the toolbar glass cannot be measured and
are counted as `toolbar-occluded` (1 to 5 per transition).

| Run (final build) | Transitions | Stack vs keyboard lag | TUI last row vs stack |
| --- | --- | --- | --- |
| iOS 26.5 dark | 5 composer + 3 TUI | -0.34 .. +1.00 pt, one frame -1.67 pt | -0.47 .. +0.31 pt |
| iOS 27.0 dark | 5 composer + 3 TUI | -0.55 .. +0.67 pt | -0.41 .. +0.20 pt |

The stack moves on the keyboard's curve from its resting line (784 pt) to
8 pt above the keyboard (558 pt on 26.5, 565 pt on 27.0). +0.67 pt is the
last frame of a hide; the -1.67 pt frame matches the single outlier the
standalone screen showed in `terminal.md`. Results:
`ios2?-ws-terminal-dark.keyboard.txt`, per-frame tables in `frames/`.

Comparison strip: `cmp/terminal-tab.png` (ours in dark and light, keyboard
up and down, TUI) next to `grok-03-composer-typed`, `chatgpt-16` and
`grok-06-scroll-edge-top`.

## 2. Walkthrough

`verify/polish-walkthrough.sh <udid> <prefix>` records, in dark and light:
`onboarding` (signed out: welcome, email sheet, email typed and sent, code
typed, team pick, notifications, Home), `tour-a` (Home, Chief and a send,
back, Workspaces, a workspace on its last tab, grid, terminal tab with
keyboard and send, grid, agent tab, leave), `tour-b` (Feed: scroll, Show
more, inline answer, open event, a streamed agent turn with permission and
question, diff file, expand, Split, Unified, Changes), `tour-c` (Settings
transport switch, sidebar, team switch, appearance editor color and emoji),
`ws-terminal`. Sheets of one frame per demo mark: `sheets/`; dense frame
splits with `scripts/frames.sh`, layout oscillation with
`scripts/flicker_check.py`.

### Bugs found and fixed

| # | Found (frames) | Cause | Fix |
| --- | --- | --- | --- |
| 1 | Terminal tab: chrome twice (terminal nav bar + TabsKit toolbar) | full `TerminalScreen` in the page | embedded chrome (section 1) |
| 2 | Terminal page blank for ~2 s after leaving htop | first primary-screen report still described the alternate screen; the surface was placed at row 0 | report-driven placement until the user scrolls; active area requested once the switch is processed |
| 3 | Composer said "Typing into terminal" after htop quit with the keyboard down | direct typing kept for TUI | ends with the TUI unless the surface keeps focus |
| 4 | Files and Links: stack jumped to the top of the screen and stayed | SwiftUI `.sheet` inside the TabsKit page left the keyboard layout guide at 172 pt | presented from UIKit |
| 5 | iOS 26: scrollback sharp under the status bar | no top edge effect for a bare container on 26 | gradient scrim (iOS 26 only) |
| 6 | Agent tab after a grid zoom: page alternated between two layouts for ~0.4 s; one run in nine hung the app (100 % CPU, endless layout) | the transcript's bottom margin counted the jump button, which toggles on the distance to the bottom, which depends on the margin | margin measured from the composer group only; 4/4 reruns clean, no reversals after the zoom |
| 7 | iOS 26: agent page blank after a workspace opened or a tab zoomed in | LazyVStack estimates (1450-1538 pt vs 769 pt) let the bottom anchor settle past the content | VStack |
| 8 | Agent page built during a zoom: newest turn under the composer | laid out before the composer was measured | a following chat scrolls to its bottom when the page settles |
| 9 | iOS 27 Home: large title collapsed to inline | `.searchable(.navigationBarDrawer(.always))` on iOS 27 | search field as a list row under the large title |
| 10 | Light mode: email field and empty code boxes invisible | sheet and field both `#F2F2F7` | light sheet is white |
| 11 | iOS 27 keyboard: "slide to type" tip over the keyboard | first keyboard on a fresh simulator | simulator setup (`DidShowContinuousPathIntroduction`) |
| 12 | Light mode terminal tab: light glass composer and key bar over the black grid | hosting controllers followed the app appearance | key bar and composer pinned to dark like the terminal |
| 13 | iOS tests did not compile with Xcode 26.3 | `ambiguous use of operator '-'` (CmuxTabsKit swipe fade), `withAnimation` returning `Set.insert`'s tuple (FeedCell) | explicit types; discard the result |

Final state: all 20 recordings (5 segments x dark/light x iOS 26.5/27.0)
reach their last demo mark; the reviewed sheets show no remaining layout
or contrast bug in the walked screens. Checked and matching: the team editor
selection follows the stored color, the transport picker reflects the switch,
the diff viewer in both appearances, Feed inline answers and Show more,
the onboarding steps in both appearances (after fix 10).

## 3. Live terminal tabs (daemon channel)

`DaemonTerminalSession` (CmuxMobileLive) implements `TerminalSession` over a link's
`daemon` channel, one channel per terminal tab: `attach-surface {surface}`
(bytes mode; `vt-state` replay and `output` chunks into the Ghostty mirror,
`resized` resets the mirror with `ESC c` and replays, `detached` ends),
`send {surface, bytes}` and `resize-surface {surface, cols, rows}` in order
(the size waits for the attach). The alternate screen flag comes from the
bytes. `LiveCoordinator.terminalSession(tabID:)` maps `s<surface>` tabs to
sessions on the current link; `GhosttyTerminalTabContent` uses it in live
mode and the mock otherwise (one line in `RootView`).

Checked against a real cmux-tui server (nightly build, isolated session and
HOME under `~/cmux-next-ios-e2e/polish/tui` on the mini, stopped afterwards) with
`verify/scripts/daemon_attach_probe.py`: event names and fields
(`vt-state.data`, `output.data`, `resized.replay`), reply envelopes, `send`
bytes and `resize-surface` match the parser. Not yet run end to end through
`cmux-mobile-host` and the app (needs the live sign-in setup from `live.md`); the
hostd allowlist must pass `attach-surface`, `send` and `resize-surface`.

## 4. Unit tests

- macOS `swift test` in `cmux-next-ios/CmuxMobileKit`: 55 tests pass. `CmuxMobileTerminal` links
  CmuxGhosttyKit only on iOS (it broke linking `CmuxMobileTerminalTests` on macOS);
  `WorkspaceSort` moved out of the iOS-only list view.
- iOS: `xcodebuild test -scheme CmuxMobileKit-Package` on `mini-cmuxs-mac-mini-2`
  (Xcode 26.3, iPhone 17 Pro iOS 26.3 simulator created for the run and
  deleted afterwards, sources rsynced to `~/cmux-next-ios-e2e/polish/src`):
  **65 tests pass** (`** TEST SUCCEEDED **`). New: `DaemonTerminalSession`
  against a fake daemon (attach, replay, surface filter, input, resize order,
  `resized`, attach failure) and `TerminalTabEmbeddingTests` (terminal actions
  lead the page menu, grid opening prepares the active terminal card).

## Remaining gaps

- Live terminal: not exercised end to end in the app (see section 3). The
  grid policy question from `terminal.md` stands: the phone resizes the
  Mac's terminal to its TUI grid (`resize-surface`), which shared sizing on
  the Mac may or may not accept.
- In light mode TabsKit's toolbar stays light glass over the black terminal
  page (TabsKit has no per-tab color scheme; the terminal's own stack is
  dark now).
- The terminal stays inside the page during a swipe or zoom (it moves with
  the page) instead of hiding like the agent tab's accessory row; the grid
  card includes the composer for the same reason, so the zoom ends on a
  matching card.
- No touch injection: pinch, swipes, back swipe and page menu taps are driven
  through the same state paths, not by fingers. The page menu contents are
  covered by a unit test, not a recording.
- The agent transcript is a plain VStack now (fix 7): very long histories
  (2000 records) lay out fully; needs a profile on a device.
- First open of an agent tab: the composer starts expanded while the mock
  history loads, then collapses.
- Out of scope for this pass (owned by other agents now): sign-in screens,
  toggle tint, workspace creation, Chief presentation, navigation structure
  and the photo picker.
