# PagedList: the one infinite-scroll list

`CmuxMobileDesign/PagedList/` holds the iPhone app's shared paginated list. It loads pages as the
reader scrolls down (`.down`: Feed, chat lists, workspaces) or up (`.up`: a chat's history, opened at
its newest row at the bottom). The UI tests are `UITests/PagedListUITests.swift`, and the DEBUG lab
is `-cmux-mobile-paged-lab DIRECTION:SCENARIO` (`CmuxMobileShell/PagedListLabRoot.swift`).

## What it guarantees

| Guarantee | How | Proof |
|---|---|---|
| A page that lands never moves the row being read | The anchor (first row under the reader's top) is captured before the snapshot apply and restored after the layout pass that placed it | `test{Down,Up}PageLandsWithoutMovingTheReader*`: row frame from outside, ≤ 0.5 pt, plus the lab probe |
| A row above the reader that changes height moves nothing | `PagedListLayout` sets `contentOffsetAdjustment` for every self-sizing change of a row that starts above the reader's top. Without it, UIKit's list jumps when you scroll up into rows that had estimated heights | Same tests at the accessibility text size (heights far from the estimate) |
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
keyboard mid-slide retarget it with no seam. A touch stops it where it is. Reduce Motion, or
`.pagedAnimatesNewest(false)`, jumps instead. A reader away from the newest end is not moved: the rows
land out of view and the newest-rows indicator counts them.

The indicator is the screen's own: `.pagedNewestIndicator { newest in ... }` draws from
`PagedListNewest` (`unseen`, `isAway` with hysteresis, `jump`). `PagedListNewestPill` is a ready-made
one; no screen uses it yet.

## Memory

`PagedListModel(direction:source:memory: .window(N))` (rows that are `Codable`) holds every row's id in
order (`PagedListOrder`, a linked list: a change anywhere is O(1)) but only about N values, the rows
around the reader (at least 120). As the reader moves, the window recenters on them (when they leave
its middle half); values that leave go to the list's spill file (`PagedListSpill`, one append-only
file in Caches, an index in memory, one serial queue off the main thread) and values that enter are
read back from it. The list shows the contiguous run in memory and an edge (spinner) at a side still
reading from disk, the same edge a page read shows. All lists' files share a 1 GB cap
(`PagedListSpillBudget`); past it a row stays in memory, so nothing is lost. Files go with their model,
and an earlier launch's files are deleted at the first spill. A live arrival beyond the window counts
toward the indicator's `unseen`; the jump brings the newest rows back first.

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
| `huge` | 100,000 rows in pages of 200, in a 300-row window |

The lab's probe measures, after every layout pass, how far the row being read moved on screen beyond
what the scroll explains (the finger, a fling's deceleration, scroll to top, the list's own slide or
ride). Corrections the list makes (anchoring, height changes) are not explanations: a frame where a
correction left the row off its place is a shift. A case fails above 0.5 pt in any frame, or above
10 ms of hitches per second. Each case prints `PAGEDLIST STRESS-<direction>-<speed>-<load> {…}`;
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

| Screen | Direction | State |
|---|---|---|
| Agent Chats (`AgentChatsScreen`) | down | **On PagedList.** Older chats load as you scroll; the Show Older Chats button is gone. The edge shows a failure with Try Again instead of an alert |
| Agent chat transcript / Chief (`ChatTranscriptList`) | up | **Shares the paging measure** (`pagedScreensToEdge(.up)`). It keeps its own layout for off-main native rows, with the same anchor rules. Next: make `PagedListController`'s layout pluggable and move the transcript's controller onto it |
| Cloud machine chats (`CloudChatsScreen`) | down | Next: replace "Show Older Chats" (`CloudChatList.pageSize`) with PagedList |
| Feed (`FeedCollection`, `UITableView`) | down | Next: it reads all events today. Page it from the Mac's `hasMore` (`LiveFeed+FullReply`), keeping its table and swipe code until a PagedList port shows equal frame numbers on the FeedStress bench |
| Workspaces list | down | Not paged (it lists all workspaces). Move it to PagedList when the Mac pages it |
| Terminal scrollback | up | Not a list (the Mac holds the scrollback window) |
