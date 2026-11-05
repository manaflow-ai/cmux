// page-window key path: deleted with detached hosting (cmux-ad m24)
import AppKit
import CmuxNextWakeups

/// The focus rules of a page shown in its own Chromium child window (the CEF fork's page window). The fork orders that
/// window out while its host view is hidden or empty, so a grant then would order it in and make it key for one layout
/// pass, and the next pass would order it out again: a Cmd-N made 31 key-window changes that way (INSTANT OWNER,
/// #36474). Detached hosting (fork API 30) has no page window and replaces this file.
extension CEFTab {
    /// The page's host has an area. An empty host is ordered out by the fork, as a hidden one is.
    var pageWindowHostHasArea: Bool { !container.bounds.isEmpty }

    /// Whether the page's window can hold the keys now: shown, with an area, and a browser (``ChildPageFocus``).
    public var canTakeKeys: Bool { isShown && pageWindowHostHasArea && browserID != nil }

    /// Keeps a focus ask the page cannot take now; granted once it can (``grantPendingFocusIfShown()``).
    public func keepFocusAsk() { pendingFocus = true }

    /// Drops a kept focus ask: the page is no longer the one its window gave focus to.
    public func dropFocusAsk() { pendingFocus = false }

    /// The host's frame changed. A focus ask kept while the host was empty is granted once, when it gets an area, after
    /// this pass's commit: the fork orders a hosted page's window in after the commit, and a key change inside a layout
    /// pass re-marks the window.
    func pageWindowHostDidResize(wasEmpty: Bool) {
        guard wasEmpty, pageWindowHostHasArea, pendingFocus else { return }
        AfterFrameCommit().run { [weak self] in self?.grantPendingFocusIfShown() }
    }
}
