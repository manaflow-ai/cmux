# CmuxTabsKit synced to upstream (2026-10-13)

`Packages/iOS/CmuxTabsKit` is now byte-identical to `origin/feat-cmux-next-tabs-kit`
at 52bf6989026d ("titles start at progress 0.90; data source notices as a glass
toast; forward glyph is the forward control's label"), which includes affa688cd012
(card close buttons and titles arrive and leave like Safari's).
`scripts/check-tabskit-sync.sh` keeps it that way (below).

## Our local edits, and where they went

| Local edit (before the sync) | Upstream covers it? | Now |
| --- | --- | --- |
| Accessory row never below its resting place during an interactive keyboard drag (`max(keyboard, resting)` in `TabsView`, 0a440aeef0b4) | No | Host code: `AccessoryFloor` in `CmuxMobileWorkspaces/WorkspaceTabsSource.swift`, a render-only lift from `TabsKitContentContext` (`pageSize`, `safeAreaInsets.bottom`, `isToolbarCollapsed`). Also proposed upstream. |
| Xcode 26.3 compile fix for the toolbar swipe fade (28bcdc4d46e0) | No | Not reachable from host code. Proposed in `tabskit-upstream-requests.md`. Xcode 27.0 (this laptop, demo builds) compiles upstream as is. |
| The other 5 differing files | They were upstream's new commits, not our edits | Taken as is. |

## Adapting to upstream API changes

- New optional `TabsDataSource.notice` / `clearNotice()` (glass toast).
  `WorkspaceTabsSource` adopts it: `createTab` on a workspace that is gone returns
  nil with "This workspace is no longer on the Mac." instead of creating an
  orphan tab.
- No other public API changed. Card chrome timing (`CardChrome`) is internal.

## The guard

- `cmux-next-ios/scripts/check-tabskit-sync.sh [--ref <sha>] [--no-fetch] [--quiet]`
  fetches both upstream branches and compares the git trees of
  `Packages/iOS/CmuxTabsKit` (`feat-cmux-next-tabs-kit`) and
  `Packages/iOS/CmuxConversation` (`feat-imsg-parity-gui`). Exit 1 on drift, with a
  diffstat and the sync command.
- `scripts/demo-build.sh` runs it on the build's SHA first: a boxed WARNING plus a
  MANIFEST build note on drift; `--strict` fails the build instead.
- At this commit: CmuxTabsKit ok. **CmuxConversation drifts**
  (`origin/feat-imsg-parity-gui` moved to c735526c2b10, scroll smoothness, 18
  files). Not synced here (out of this task's scope; the Chief adapter needs its
  own check). Demo builds will warn until it is.

## Verification

- `swift test` in `Packages/iOS/CmuxTabsKit` on macOS (Xcode 27.0): 25 tests in
  5 suites pass, including the new `CardChromeTests`.
- App: `verify/build.sh` (Debug, iOS Simulator) BUILD SUCCEEDED.
- Simulator `cmux-mobile-tk-ios26` (iPhone 17 Pro, iOS 26.5), headless, software keyboard,
  `CMUX_MOBILE_MOCK_AUTH=1` mock data, real HID touches via AXe:
  `verify/record-tabskit.sh <udid> <dir> <label>`. Evidence (gitignored):
  `verify/evidence/2026-10-13/tabskit/`.

| Step | Result | Evidence |
| --- | --- | --- |
| Open workspace "cmux" | Opens on its last-used tab (agent chat) | `ios26-01-open-last-tab.png` |
| Tabs button: grid zoom out | Page shrinks into its card; titles and close buttons fade in after the card lands (upstream's new timing) | `ios26-02-grid.png`, `strip_grid.png` (every recorded frame) |
| Tap terminal card: zoom in | Terminal page, embedded mode with composer and key bar | `ios26-03-terminal-zoomed-in.png` |
| Back to list, reopen | Lands on the terminal (last used) | `ios26-04-reopen-last-tab.png` |
| Close the browser card | Card removed, "2 Tabs" | `ios26-05-closed-card.png`, `strip_close.png` |
| Toolbar swipe between tabs | Agent to terminal and back | `ios26-07-swiped.png` |
| Agent composer, keyboard up | Composer docked 8 pt above the keyboard | `ios26-08-agent-keyboard.png` |
| Interactive dismissal drag (agent) | Composer held at its resting place (card bottom 775.7 pt) while the keyboard went from 798 to 837 pt; see below | `ios26.trace.txt` |
| Terminal, keyboard up, drag dismissal | Composer and key bar ride the keyboard; settle above the toolbar | `ios26-10/11-*.png` |

Keyboard drag, per-frame trace (`-cmux-mobile-kbd-trace`), agent tab:

| Build | Frames below rest | Worst |
| --- | --- | --- |
| Before (package patched with `max(keyboard, resting)`) | 4 | 14 pt, keyboard top 843 to 862 pt |
| After (upstream package + host `AccessoryFloor`) | 4 | 14 pt, keyboard top 843 to 862 pt |

Same behavior. Without either fix the row would follow the keyboard to about
829 pt bottom. The remaining 14 pt for 4 frames is SwiftUI's keyboard inset
(already noted in `keyboard.md`; proposal 2 in `tabskit-upstream-requests.md`).

Upstream Demo app (`Packages/iOS/CmuxTabsKit/Demo`, built from the upstream tree
in a temp copy) on the same simulator: same grid geometry, card radius, close
button size and place, title rows and bottom bar (`sbs-grid.png`: Demo grid,
mobile grid, Demo after closing a card, mobile after closing a card;
`strip_demo_grid.png` beside `strip_grid.png` for the zoom).

## Not covered

- iOS 27 (`cmux-mobile-tk-ios27`): not recorded. A first iOS 27 run failed at its first
  accessibility lookup, and the session was then limited to one booted
  simulator (iOS 26.5).
- Pinch zoom: AXe has no two-finger gesture; the grid was driven with the Tabs
  button and card taps.
- Live data: mock data only. No run against a real cmux-next Mac app build.
- Accessibility difference: in the Demo each card's close button is its own
  "Close <title>" element; in mobile, with live page content in the cards, it is
  not exposed by that name (the script falls back to a coordinate tap).
