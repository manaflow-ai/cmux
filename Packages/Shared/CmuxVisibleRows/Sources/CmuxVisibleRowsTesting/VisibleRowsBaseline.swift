/// The lists registered with the visible-rows contract that do not meet it yet: name (`VisibleRowsFixture.name`) to
/// why, and the lane fixing it. `VisibleRowsContract.check` runs these inside `withKnownIssue`, so a fix that makes one
/// pass fails its test until the fix deletes its line here. Lines are only deleted or narrowed: a new list meets the
/// contract, or its PR says why it may not. The count of lines is the number of known failures.
// lint:allow namespace-type: the one list of known failures, a constant table read by VisibleRowsContract.check.
public enum VisibleRowsBaseline {
    public struct Known: Sendable {
        /// What the list does today, and `fix: <lane>`.
        public var why: String
        /// Only issues whose message contains this are known (a list that meets every rule but one); nil: any.
        public var only: String?

        public init(_ why: String, only: String? = nil) { (self.why, self.only) = (why, only) }
    }

    public static let knownFailures: [String: Known] = [
        "notifications panel": Known("the daemon answers each change with the whole ledger (up to 256 entries), and the panel reads "
            + "all of it to find what changed (macOS NotificationsPanelList.show; fix: visible-only-macos-lists)", only: "items walked"),
        "page popup": Known("rows are windowed and kept by id, but the page sends the whole model each revision, so the diff "
            + "reads every row (macOS NativePopupContent.update; fix: row deltas on the popup wire)", only: "items walked"),
        "page menu": Known("rows are windowed and kept by index, but the page sends every item each time, so the diff "
            + "reads every item (macOS WebPopupRows.update; fix: item deltas on the popup wire)", only: "items walked"),
        "sidebar pinned band": Known("its item views are windowed, but each change lays every item of the band out again and "
            + "indexes them (macOS SidebarRegionView.update, indexItems; fix: visible-only-macos-sidebar-bands)", only: "items walked per"),
        "sidebar chats": Known("the page draws a row for every chat in its block: rows alive grow until the page windows "
            + "against the slice (macOS SidebarChatHistoryHost streams cmux.page.visibleSlice; fix: visible-only-pages)"),
        "sidebar priority": Known("draws only the rows in view, but each change hands the whole ranked list, which the panel "
            + "compares and reindexes (two cheap passes over every chat; macOS SidebarPriorityPanelView.show; fix: a row patch "
            + "from SidebarPriorityFeed, visible-only-macos-lists)", only: "items walked"),
    ]
}
