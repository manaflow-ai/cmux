# Workspaces list (ChatGPT-style): verification

Branch `feat-cnx-ios-wslist2`, 2026-10-13. Evidence is git-ignored, in
`verify/evidence/2026-10-13/wslist2/`.

The user rejected the previous redesign (an "All Macs ⌄" title menu, sticky
per-Mac headers, three-line rows with branch, tab glyphs and a status line).
They chose a "ChatGPT-style sidebar list":

```
[All] [Studio] [mini 2]
Today
● cmux
  cmux.com
Yesterday
  fleet
  notes
```

References: `~/Downloads/cmux-native-references/ChatGPT/chatgpt-03-sidebar`
and `chatgpt-23-sidebar-selected-expanded` (one-line names in `body`, about
44 pt per row, no icons or separators, text about 30 pt from the edge, a
rounded fill on the selected row), and ChatGPT's history grouping (Today,
Yesterday, Previous 7 Days, Previous 30 Days, then months, by last activity).

## What changed

- **Mac chips** replace the title menu: All, then one chip per Mac, online
  first. The chosen chip is filled with the foreground color; offline Macs'
  chips are dimmed. Remembered per team (`MacFilter`, unchanged key
  `cmuxMobile.workspaces.macFilter.<team>`). All mixes every Mac with no per-Mac
  headers. Holding a Mac chip shows its presence (and the live link line) as
  the menu header, with Show Workspaces and Reconnect (live only). The row is
  a `safeAreaInset` with an opaque background.
- **Rows**: one line, the name in `body`, 46 pt minimum. A 7 pt dot in a
  leading gutter only when an agent needs the user (`warning`) or is working
  (foreground color, breathing; static with Reduce Motion). A mini spinner
  while a new workspace is created. No icon, subtitle, time or chevron.
  Pressing shows a rounded fill like ChatGPT's selected chat.
- **Recency sections** (`RecencyBucket`): Today, Yesterday, Previous 7 Days
  (2–7 calendar days), Previous 30 Days (8–30), then by month ("August";
  "December 2025" in an earlier year). Headers are small `footnote`
  semibold secondary rows that scroll with the list, not pinned.
- **Search**: `.searchable` in the navigation bar drawer, tucked under the bar
  at launch and revealed by a pull-down, as in ChatGPT and Mail. Matches the
  name, branch and directory within the chosen chip. No results uses
  `ContentUnavailableView.search`.
- **Row menu** (long press), headed "<Mac> · <branch or directory>"
  ("· Offline"): Open, Rename (alert with a field), Close Workspace
  (destructive, confirmed).
- **Swipe left**: Close (system destructive style, confirmed). There are no
  leading swipe actions, because a rightward edge swipe opens the team drawer.
- **Rename and close** are new: `WorkspaceCreator.rename` / `close` apply at
  once and are undone if the Mac refuses (a toast through
  `onManageFailure`). The backend protocol gained `canManage`, `rename` and
  `close`, with "unsupported" defaults. The mock supports both. Live sends
  `rename-workspace {key, name}` and `close-workspace {key}` to the linked
  Mac's daemon (both allowed by the cmux-mobile-host phone lane), then relists.
- **Offline Macs' workspaces** are dimmed, have no dot and no menu actions. A
  tap explains: "MacBook Pro is offline. Last seen 2h ago. “notes” opens when
  the Mac is awake with cmux running."
- **New Workspace** is unchanged: a tap creates at once on the chosen chip's
  Mac (or the preferred Mac under All) and pushes it. A hold opens the start
  options, with the Mac picker only under All. It is disabled while the chosen
  Mac is offline.
- **Empty states per chip**: online Mac with none ("No workspaces on
  <Mac>", New Workspace), offline Mac with none ("<Mac> is offline", last
  seen), All with none, every Mac asleep, and no search results. The chips
  stay visible above each one.
- **Removed**: the title menu and subtitle, the More menu (Sort, Show
  Offline Macs), sticky per-Mac headers with Reconnect, the three-line row,
  `WorkspaceSort`, `TabKindSummary`, `WorkspaceActivity` and `MacSection`.
- `MockData`: four older workspaces (3, 12, 45 and 80 days), so every
  recency section shows.

## Bugs found while verifying

- **Pull-down never came back.** With the chips in a `safeAreaBar`, a long
  list that had hidden the search drawer never showed it again on a pull.
  It worked with a short list. With a `safeAreaInset` the pull works on both.
- **Blank white swipe button.** The app tints controls with the foreground
  color (`RootView` `.tint(label)`), so the destructive swipe action drew a
  white pill with a white label in dark mode. `.tint(nil)` on the button
  restores the system red. This is the same root cause as the Home and Feed
  swipe fix.
- **Chips were missing from accessibility** under an
  `.accessibilityElement(children: .contain)` wrapper, so VoiceOver and axe
  could not reach them. The wrapper is gone; each chip is a button with an
  id, its presence as the value, and the selected trait.

## How it was verified

- **Unit tests** (Swift Testing on macOS): `swift test --filter
  CmuxMobileWorkspacesTests` (17 passed), `CmuxMobileModelTests` (36 passed) and
  `CmuxMobileLiveTests` (passed). `MacFilterTests.swift` now covers:
  - the filter memory (unchanged)
  - recency buckets on calendar days, with a fixed time zone and midnight
    edges
  - section titles, including a month in an earlier year
  - All mixing every Mac newest first, one Mac (online or offline)
  - search on name, branch and directory
  - chip order, and the New Workspace target
  - rename and close applied at once, a refusal undone with
    `onManageFailure`, and offline or blank-name refusals
- **Simulator**: `cmux-mobile-wl2-ios26` (iPhone 17 Pro, iOS 26.5), headless
  (Simulator.app never opened), `CMUX_MOBILE_MOCK_AUTH=1`, Debug build with
  `xcodebuild -jobs 4`. Only one simulator ran at a time, by the
  coordinator's rule after the Mac ran out of processes. The iOS 27
  simulator was not run in the end. The first iOS 27 screenshot, before the
  process-limit incident, matched iOS 26.
- **Real touches**: `verify/record-wslist.sh <udid> <dir> [dark|light]
  [content-size]` drives HID taps, swipes, a long press and typing with
  `axe` while `simctl io recordVideo` records. It saves a screenshot per step
  and 2 fps frames. Chips are tapped by accessibility id; the chip row is
  scrolled first when the chip is off screen. (The script was removed in the Inbox redesign,
  2026-10-13, with the chips; `verify/record-wsdesign.sh` replaces it.)

| Check | Result | Evidence (`wslist2/`) |
| --- | --- | --- |
| All: chips, recency headers, one-line rows, dots on cmux (needs you) and cmux.com (working), offline rows dimmed | Yes | `ios26-dark/01-all.png` |
| Search tucked at launch, revealed by a pull-down | Yes | `01-all`, `02-pulled-search` |
| Search "cm" matches names and directories, keeps the headers | Yes | `03-search-results` |
| Studio chip: only its workspaces, chip filled | Yes | `04-studio` |
| Offline Mac chip (dimmed, filled at lower opacity) with dimmed rows; a tap explains | Yes | `05-offline-mac`, `06-offline-explained` |
| Offline empty and online empty states, chips still shown | Yes | `07-offline-empty`, `08-online-empty` |
| Empty state's New Workspace creates on MacBook Air and pushes; edge swipe back shows it under Today | Yes | `09-created-pushed`, `10-back-on-air` |
| Long press: header "Aziz's Mac Studio · main", Open, Rename, Close Workspace | Yes | `11-row-menu` |
| Rename alert prefilled; renamed in place | Yes | `12-rename`, `13-renamed` |
| Swipe left: red Close, confirmed popover "Close “fleet”? Its tabs close on cmux mini 2." | Yes | `14-swipe-close`, `15-close-confirm`, `16-closed` |
| Chip survives a relaunch, scrolled into view | Yes | `17-mini2`, `18-relaunched` |
| Light mode: chips, rows, red swipe action | Yes | `light/*.png` |
| `accessibility-large`: rows and headers scale, chips scroll | Yes | `ax/*.png` |
| Recording | Yes | `ios26-dark/walk.mp4`, `ios26-dark/frames/` |
| After merging `origin/feat-cnx-ios` (swipe tint fix landed there too): list and red Close, tests 17/40/44 passed | Yes | `merged/swipe.png` |

Side by side with `chatgpt-03-sidebar` and `chatgpt-23`: the same one-line
`body` rows at the same rhythm (46 pt here, about 44 pt there), the same text
inset (30 pt), no separators or icons, and a rounded fill on press. ChatGPT
has no recency headers in its current drawer; their names and grouping follow
its full history list.

## Known gaps

- Live mode was not exercised on a device: no real cmux-next Mac app build
  was attached in this round, and live verification must not use helpers or
  stubs. Rename and close reach only the linked Mac, as creation does.
  `canManage` hides the actions elsewhere.
- Live workspaces carry no activity time from the Mac
  (`DaemonTree` stamps first sight), so in live mode most rows sit under
  Today until the daemon reports activity times.
- The swipe action hides the row's name while open (the row slides by the
  action's width). This is system behavior.
