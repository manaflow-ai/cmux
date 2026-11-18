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
| Bounded memory | Cells are reused (O(rows on screen) views). The height cache is pruned to live rows on every update. Items are values; screens with heavy rows bound them in their store (the chat transcript's spill) | — |

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
| 2 | Cloud machine chats (`CloudMachineChatsList` in `CloudChatsScreen`) | down | **On PagedList.** A page of 100 more of the chats the hub holds shows as you scroll (`CloudChatList.pageSize`); Show Older Chats is gone. While the hub still reads older chats (CMUX-563 pages) the end spins; if that read stopped (`AcpmuxHub.listRestStopped`) the end offers Try Again, which reconnects. Gallery `-cmux-mobile-paged-lab cloudchats:SCENARIO`, tests `UITests/CloudChatsPagedListUITests.swift` |
| 3 | Chief Home conversations (`ConversationsHome` / `MacHomeList`) | down | Next candidate. A SwiftUI `List` of every conversation, re-sorted live as messages land. Not paged by the Mac today; PagedList would keep the reader in place when a conversation moves to the top. Needs its swipe buttons and menus (`HomeRowSwipeButtons`, `HomeRowMenu`) ported to `PagedListAction`s and context menus |
| 4 | Feed (`FeedCollection`, `UITableView`) | down | Already pages older events back from its disk spill (`FeedStore.loadOlder`, 30 rows before the end) and keeps its own off-main row layouts. Keep its table and swipe code until a PagedList port shows equal frame numbers on the FeedStress bench; then page it from the Mac's `hasMore` (`LiveFeed+FullReply`) |
| 5 | Workspaces list (`WorkspacesCollection`) | down | Not paged (it lists all workspaces, already a `UICollectionView` list with a height cache). Move it to PagedList when the Mac pages it |
| 6 | Agent chat transcript / Chief (`ChatTranscriptList`) | up | Not migrated: it lays rows out off the main thread (`ChatTranscriptLayout`, markdown while streaming). **Shares the paging measure** (`pagedScreensToEdge(.up)`) and the same anchor rules. Next: make `PagedListController`'s layout pluggable and move the transcript's controller onto it |
| — | Artifacts (`ArtifactsBrowser`, terminal `ArtifactsSheet`) | — | Not paged: a session's artifacts, bounded and filtered on the phone |
| — | Cloud machines, Cloud automations, the Cloud chats machine picker (`CloudMachinesScreen`, `CloudAutomationsScreen`, `CloudChatsScreen`) | — | Not paged: a team's machines and automations, tens of rows, no growth while open |
| — | Diff (`DiffCodeList`) | — | Not a paged list: one file's lines, with its own virtualized layout |
| — | Settings pages, sheets and pickers | — | Static lists |
| — | Terminal scrollback | up | Not a list (the Mac holds the scrollback window) |
