# PagedList: the one infinite-scroll list

`CmuxMobileDesign/PagedList/` holds the iPhone app's shared paginated list. It loads pages as the
reader scrolls down (`.down`: Feed, chat lists, workspaces) or up (`.up`: a chat's history, opened at
its newest row at the bottom). The UI tests are `UITests/PagedListUITests.swift`, and the DEBUG lab
is `-cmux-mobile-paged-lab DIRECTION:SCENARIO` (`CmuxMobileShell/PagedListLabRoot.swift`).

## What it guarantees

| Guarantee | How | Proof |
|---|---|---|
| A page that lands never moves the row being read | The anchor (first row under the reader's top; for an `.up` list at its newest end, the lowest row's bottom, so a change above pushes the older rows up as in Messages) is captured before the snapshot apply and restored after the layout pass that placed it | `test{Down,Up}PageLandsWithoutMovingTheReader*`: row frame from outside, ≤ 0.5 pt, plus the lab probe |
| A row above the reader that changes height moves nothing | `PagedListLayout` sets `contentOffsetAdjustment` for every self-sizing change of a row that starts above the reader's top. Without it, UIKit's list jumps when you scroll up into rows that had estimated heights | Same tests at the accessibility text size (heights far from the estimate) |
| A layout pass mid-scroll moves nothing | While a finger or a fling moves the list away from its newest end, each layout pass keeps the row under the reader's top edge where it was drawn when the pass started (a row above that changed out of view, a window move); between passes the scroll moves it. A `.down` list's slide to new rows at its top holds them the same way (the rows it reveals size themselves as they come into view). An update that only changes rows' values (an edit that grows a row) mid-scroll or mid-slide keeps the reader like one that adds or removes rows. At rest, every pass puts the reader back where the last one left it. (A row that straddles the reader's top edge and changes height keeps its top, at rest and mid-scroll: the rows below it move. Follow-up: make the layout's above-the-reader rule agree, so the adjustment doesn't move it first.) | `testWindowedHugeListKeepsMemoryBounded` and the stress bench (`frameShift` ≤ 0.5 pt while scrolling under load) |
| No re-measure flicker | Heights are cached per row value, width and text size. A row that comes back into view takes its height without a SwiftUI sizing pass | Fling tests (frames and hitches in `PAGEDLIST` lines) |
| No blank edge on a fling | The next page is asked for 2 screens before the edge (`UIScrollView.pagedScreensToEdge`), on every scroll step and after every update | `test*FlingsMeetRowsWithoutHitches`: >90 rows read during flings |
| `.up` opens at, and stays on, the newest row | Each layout pass of a following list re-pins to the bottom (keyboard, rotation, a sent row, a row that grew). A short list sits at the bottom (top inset). A reader in the middle keeps the bottom edge's distance when the height changes | `testUpStaysOnNewestThroughKeyboardAndSend`, `testUpLiveRowsKeepAReaderAboveInPlace` |
| Every state | First page: loading, failed + Try Again, empty. Edge: more/loading (spinner), failed + Try Again, end (optional label). The edge row keeps one height across states | `testLoadingFirstPage`, `testFirstPageFailureThenTryAgain`, `testEmpty`, `testEdgeFailureThenTryAgain`, `testEndOfList` |
| Bounded memory | Cells are reused (O(rows on screen) views). The height cache is pruned to live rows on every update. With `memory: .window(N)` the model keeps about N row values in memory and the rest on disk ("Memory") | `testWindowedHugeListKeepsMemoryBounded`, `PagedListModelGuardTests` |
| No layout shift in any frame, under load | The per-frame shift measure ("Stress bench") fails a frame where the row being read moved for a reason other than the scroll | `PagedListStressUITests` (direction × speed × load), the `ios-pagedlist` bench |
| New rows at the newest end slide in | A critically damped spring on the display link ("New rows at the newest end") | `testUpStaysOnNewestThroughKeyboardAndSend`, `testDownNewRowSlidesInAtTheTop` (slide frames > 5) |
| The rows ride a composer and the keyboard | `pagedBottomAccessory` pins any view to `keyboardLayoutGuide`; the list's bottom edge is its top ("Bottom edge", "Bottom accessory") | `testUpComposerRidesTheKeyboardMidList` |
| Pages are read once | "Paging guards" | `PagedListModelGuardTests` |

## Bottom edge

The list's bottom edge is what covers its bottom: the home indicator, a tab bar, a composer, the
keyboard. When it moves, `PagedListBottomPinning` says what the rows do:

- `.ridesBottomEdge` (the `.up` default, Messages and Telegram): the rows move with the edge, so the
  row above the composer stays above it as the keyboard comes and goes. A reader at the newest row
  stays on it.
- `.keepsRows` (the `.down` default): the rows stay where they are on screen; the edge covers or
  uncovers the bottom.

`.pagedBottomPinning(_:)` overrides the default.

## Bottom accessory

`.pagedBottomAccessory(followsKeyboard:) { anyView }` pins any SwiftUI view under the rows (a composer,
a reply bar, a toolbar, a custom panel). The view's bottom rides `keyboardLayoutGuide`, so UIKit moves
it in the keyboard's own animation and with the finger in an interactive dismissal; the list's bottom
inset is the view's top, set in the same layout pass, and the rows answer it as the pinning says. The
view grows on its own (SwiftUI) animation inside a tall transparent host, and touches above it reach
the rows. `followsKeyboard: false` keeps it at the bottom (a toolbar that the keyboard covers). The
first page's states (loading, failed, empty) show over the rows so the accessory keeps its focus.
A screen with no accessory and no newest-rows indicator keeps the plain list (no host controller).
`.pagedBottomAccessory(background: .bar) { composer }` gives the view a background that reaches down
past the home indicator and behind the keyboard, so no row shows under or below the composer; without
`background:` the view draws its own (or none). The host ignores only the keyboard and the bottom
container safe area when an accessory is set, so the rows still stop under a navigation bar or banner.

## New rows at the newest end

A reader at the newest end sees rows that arrive slide in, as in Messages: an `.up` list keeps its
offset for the frame the row lands (it is under the composer), then `PagedListScrollSpring` slides the
offset to the new bottom; a `.down` list keeps the rows in place for that frame, then slides to the
new top. The spring is critically damped (no overshoot), its response is the theme's `smooth` motion
(0.35 s), it runs on a `CADisplayLink` at up to 120 Hz and places the offset for each frame's
`targetTimestamp`. The target is read every frame, so another arrival, a row that grows or the
keyboard mid-slide retarget it with no seam, and the spring starts each frame from where the list
is, so the list keeping its rows in place as another row lands is not undone. A finger resting on the
list (touching, not dragging) holds the slide where it is, and it carries on when the finger lifts;
rows that arrive under a resting finger stay out of view (the rows under it don't move) and slide in
when it lifts. A drag stops the slide, and rows held for the finger then count on the indicator; rows
that arrive while a drag or a fling is at the newest end land out of view, the list still counts as
at its newest end within their height, and when the scroll ends there it slides on to them. The
indicator's jump stops a fling first. The spring ends when the offset reaches its target, also when UIKit rounds
the offset to the pixel. Reduce Motion, or
`.pagedAnimatesNewest(false)`, jumps instead. A reader away from the newest end is not moved: the rows
land out of view and the newest-rows indicator counts them.

The indicator is the screen's own: `.pagedNewestIndicator { newest in ... }` draws from
`PagedListNewest` (`unseen`, `isAway` with hysteresis, `jump`). It sits at the newest end: above the
bottom edge of an `.up` list, under the top edge of a `.down` one, so it never covers the older edge's
spinner or Try Again. `PagedListNewestPill` is a ready-made one; no screen uses it yet.

## Memory

`PagedListModel(direction:source:memory: .window(N))` (rows that are `Codable`) holds every row's id in
order (`PagedListOrder`, a linked list: a change anywhere is O(1)) but only about N values, the rows
around the reader (at least 120). As the reader moves, the window recenters on them (when they leave
its middle half); values that leave go to the list's spill file (`PagedListSpill`, one append-only
file in Caches, an index in memory, one serial queue off the main thread) and values that enter are
read back from it. The list shows the contiguous run in memory and an edge (spinner) at a side still
reading from disk, the same edge a page read shows. All lists' files share a 1 GB cap
(`PagedListSpillBudget`); past it a row stays in memory, so nothing is lost. Files go with their model,
and an earlier launch's files are deleted when the first windowed list is made. A live arrival beyond
the window counts toward the indicator's `unseen`; the jump brings the newest rows back first.

The window's own guards:

- Reaching the window's end moves it around the row being read, which ends a quarter window from the
  side the window leaves. Asking again, before or after the rows are back, moves nothing, and no move
  starts while a disk read runs, so the window never passes the reader.
- A row changed while its disk read runs keeps the change: the read's older value is dropped and the
  row read again. A list read again from its first page drops every older read's answer.
- A row the disk cannot give back (a failed read, a damaged record) is dropped from the list once
  (`lostRows`), not asked for forever.
- Rows read back from disk at the newer edge are not new rows: they don't count on the newest-rows
  indicator, and the list does not follow them (only a list that holds its newest row follows it).

Why disk and not only dropping values to refetch them: a live list's rows (edits, inserts, moves) are
not what the server pages return any more, so a refetch would lose changes. SQLite would add a schema
and a dependency for what is an id → bytes map read in order.

## Paging guards

Pagination bugs are mostly duplicate work; the model owns every guard so a screen cannot get them wrong:

- one first-page read at a time: a second refresh waits for the first instead of reading again;
- a refresh drops the answers it replaced (a generation token), including an older page in flight;
- one older read at a time (the edge is `.loading` while it runs);
- a cursor the source already gave stops the edge (it would read the same page forever), and so do
  8 empty pages in a row (`stoppedLoops` counts both);
- ids are de-duplicated within a page, against rows already read, and in live arrivals;
- a first page read again merges into the rows read so far (`mergeHead`): the older pages and the
  reader in them stay, and nothing is read twice.

## Stress bench

`PagedListStressUITests` scroll the lab under a `PagedStressSource` load (`-cmux-mobile-paged-lab-stress`):
every direction (down, up) × speed (slow held drags, medium short flings, fast flings) × load:

| Load | What arrives while the reader scrolls |
|---|---|
| `flood` | 40 newest rows/s, 120 edits/s (head, middle, tail; half change a row's height), 20 mid-list inserts/s, 6 removals and 6 moves/s, a 1000-edit burst every 2 s, pages with 50–800 ms jitter, every 9th page failing, a page that repeats a row, rows taller than the screen |
| `edits` | 300 edits/s and a 2000-edit burst every 2 s |
| `inserts` | 80 mid-list inserts/s, 20 removals and 20 moves/s |
| `busy` | `flood` with the main thread busy 4 ms of every 50 (hitches measured, not judged) |
| `huge` | 100,000 rows in pages of 200, in a 300-row window, with 10 newest rows/s, 60 edits/s, 10 mid-list inserts/s, 5 removals and 5 moves/s and a 1000-edit burst every 2 s |

The lab's probe measures, after every layout pass, how far the row being read moved on screen beyond
what the scroll explains (the finger, a fling's deceleration, scroll to top, the list's own slide or
ride). Corrections the list makes (anchoring, height changes, staying on the newest row when a page
lands above it) are not explanations: a frame where a correction left the row off its place is a
shift. An offset move inside an update or a layout pass (a row above that sized itself, UIKit's own
batch-update or self-sizing adjustment) is never the finger or a fling, which move it between passes,
so it is a correction too (the layer's layout around `layoutSubviews` counts as the pass). The sample is taken once per update and once per layout pass, after the
list's corrections, on the row the list keeps still: the top of the row being read, or, for an `.up`
list at its newest row, the bottom of the lowest row on screen (the list keeps that on the bottom edge,
and a row there that grows grows upward). A `.down` list mid-slide keeps its rows the same way. In the lab, `worstShift` names what the list was
doing in the worst frame, with a trail of every offset move since the frame before and how the
measure read it (`c` correction, `o` the list's own move, `U`/`L`/`S` inside an update, a layout pass
or the layer's layout, `p` a layout adjustment UIKit announced, `d`/`t`/`u` a drag, a resting finger
or a fling, `K` UIKit moving the offset further inside the finger's or the fling's own set of it (it
sizes rows above as they come into view and moves the content by as much: nothing moves on screen),
`n` none of these; `A` is an adjustment announced, `^` one made inside another scroll callback). A case fails above 0.5 pt in any frame, or above
10 ms of hitches per second. The landing measure (`landing_shift_pt`) judges a landing at rest only: when the finger, a fling or the list's slide moved the offset before it is read, the per-frame measure judges it. Each case prints `PAGEDLIST STRESS-<direction>-<speed>-<load> {…}`;
`scripts/bench/cmux-bench ios-pagedlist --host fleet --arg ref=SHA` runs the suite on a fleet
simulator and records the rows (frame_shift_pt, shifted_frames, landing_shift_pt, hitch_ms_per_s,
worst_frame_ms, dropped_frames, in_memory_rows, disk_bytes).

## Apple's list optimizations

| Optimization | Used | Why |
|---|---|---|
| Cell reuse, diffable data source, `reconfigureItems` (not reload) for changed rows | Yes | Changed rows keep their cell; no fade |
| Self-sizing with a per-value height cache | Yes | A row back in view takes its height without a sizing pass |
| `contentOffsetAdjustment` on self-sizing | Yes | The reader stays put when a row above changes height |
| `UICollectionViewDataSourcePrefetching` | Yes, `.pagedPrefetch { ids in } cancel:` | Screens with per-row images or avatars start loading before the row shows |
| `selfSizingInvalidation = .enabledIncludingConstraints` | Yes | A SwiftUI row that grows in place (an edit, a streaming row) resizes itself with no snapshot apply, and the layout keeps the reader |
| `applySnapshotUsingReloadData` | No | It drops the diff and the reader's anchor: worth it only for a full replace with no rows in common (a filter switch on a huge list), which a screen can do by giving a new model |
| Diffing off the main thread | No | Changes coalesce to one apply per run-loop turn, over the rows shown (the window, with a bounded model); UIKit applies a snapshot on main either way, and the stress bench's hitch numbers show whether it needs to move |
| Measuring heights before rendering | Partly (the cache) | A SwiftUI row can only be measured on the main thread by building it. Pre-measuring rows ahead of the reader in idle time is possible later if fling numbers need it |

## Why UIKit under SwiftUI rows

- **SwiftUI `List` / `ScrollView` + `LazyVStack`:** a prepend at the top moves the content. `scrollPosition(id:)`
  restores it a frame later, which shows as a flicker. `LazyVStack` estimates the heights of rows it has not
  built, so scrolling up into them jumps. There is no hook to adjust the offset while a row
  self-sizes. Swipe actions exist only in `List`.
- **`UICollectionView` + diffable data source + the list layout (chosen):** the same base as the workspaces list
  (`WorkspacesCollection`, with height cache and swipe actions) and the Feed (`UITableView`). It gives native
  swipe actions and scrolling, and one subclass hook (`invalidationContext(forPreferredLayoutAttributes:)`)
  keeps the reader in place. Rows stay SwiftUI through `UIHostingConfiguration`, so screens write SwiftUI
  only.
- **A fully custom layout** (the chat transcript's `ChatTranscriptLayout`) is needed only where rows lay out off
  the main thread (markdown blocks while streaming). It already keeps the reader in place the same way.

## Screens

Survey of every list in `cmux-next-ios/` that pages, could page, or grows live (2026-11-17), in
migration order: where PagedList clearly applies and the change is small comes first.

| # | Screen | Direction | State |
|---|---|---|---|
| 1 | Agent Chats (`AgentChatsScreen`) | down | **On PagedList.** Older chats load as you scroll; the Show Older Chats button is gone. The edge shows a failure with Try Again instead of an alert |
| 2 | Cloud machine chats (`CloudMachineChatsList` in `CloudChatsScreen`) | down | **On PagedList.** A page of 100 more of the chats the hub holds shows as you scroll (`CloudChatList.pageSize`); Show Older Chats is gone. While the hub still reads older chats (CMUX-563 pages) the end spins; if that read stopped (`AcpmuxHub.listRestStopped`) the end offers Try Again, which reconnects. Gallery `-cmux-mobile-paged-screen cloudchats:SCENARIO`, tests `UITests/CloudChatsPagedListUITests.swift` |
| 3 | Chief Home conversations (`ConversationsHome` / `MacHomeList`) | down | Next candidate. A SwiftUI `List` of every conversation, re-sorted live as messages land. Not paged by the Mac today; PagedList would keep the reader in place when a conversation moves to the top. Needs its swipe buttons and menus (`HomeRowSwipeButtons`, `HomeRowMenu`) ported to `PagedListAction`s and context menus |
| 4 | Feed (`FeedCollection`, `UITableView`) | down | Already pages older events back from its disk spill (`FeedStore.loadOlder`, 30 rows before the end) and keeps its own off-main row layouts. Keep its table and swipe code until a PagedList port shows equal frame numbers on the FeedStress bench; then page it from the Mac's `hasMore` (`LiveFeed+FullReply`) |
| 5 | Workspaces list (`WorkspacesCollection`) | down | Not paged (it lists all workspaces, already a `UICollectionView` list with a height cache). Move it to PagedList when the Mac pages it |
| 6 | Agent chat transcript / Chief (`ChatTranscriptList`) | up | Not migrated: it lays rows out off the main thread (`ChatTranscriptLayout`, markdown while streaming). **Shares the paging measure** (`pagedScreensToEdge(.up)`) and the same anchor rules. Next: make `PagedListController`'s layout pluggable and move the transcript's controller onto it |
| — | Artifacts (`ArtifactsBrowser`, terminal `ArtifactsSheet`) | — | Not paged: a session's artifacts, bounded and filtered on the phone |
| — | Cloud machines, Cloud automations, the Cloud chats machine picker (`CloudMachinesScreen`, `CloudAutomationsScreen`, `CloudChatsScreen`) | — | Not paged: a team's machines and automations, tens of rows, no growth while open |
| — | Diff (`DiffCodeList`) | — | Not a paged list: one file's lines, with its own virtualized layout |
| — | Settings pages, sheets and pickers | — | Static lists |
| — | Terminal scrollback | up | Not a list (the Mac holds the scrollback window) |
