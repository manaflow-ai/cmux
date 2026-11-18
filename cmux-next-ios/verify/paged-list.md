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

| Screen | Direction | State |
|---|---|---|
| Agent Chats (`AgentChatsScreen`) | down | **On PagedList.** Older chats load as you scroll; the Show Older Chats button is gone. The edge shows a failure with Try Again instead of an alert |
| Agent chat transcript / Chief (`ChatTranscriptList`) | up | **Shares the paging measure** (`pagedScreensToEdge(.up)`). It keeps its own layout for off-main native rows, with the same anchor rules. Next: make `PagedListController`'s layout pluggable and move the transcript's controller onto it |
| Cloud machine chats (`CloudChatsScreen`) | down | Next: replace "Show Older Chats" (`CloudChatList.pageSize`) with PagedList |
| Feed (`FeedCollection`, `UITableView`) | down | Next: it reads all events today. Page it from the Mac's `hasMore` (`LiveFeed+FullReply`), keeping its table and swipe code until a PagedList port shows equal frame numbers on the FeedStress bench |
| Workspaces list | down | Not paged (it lists all workspaces). Move it to PagedList when the Mac pages it |
| Terminal scrollback | up | Not a list (the Mac holds the scrollback window) |
