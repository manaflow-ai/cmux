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

    /// Whether the page's window can hold the keys now: shown since before this turn, with an area, and a browser
    /// (``ChildPageFocus``).
    public var canTakeKeys: Bool { isShown && pageWindowHostHasArea && !appearedThisTurn && browserID != nil }

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

    /// The page's view became shown (it entered a window, or it or an ancestor was unhidden: a Cmd-N workspace built
    /// before the key, a tab or workspace switch). A focus ask in this turn is kept and granted once, after this turn's
    /// frame commits: the fork orders the page window in and the grant makes it key, and inside the turn that change
    /// came before the first frame and held it (Time Profiler, cmux22: the grant and the window order-in, 10 ms of the
    /// swap turn). A page shown before this turn (a pane switch) still takes focus at once. The keys typed meanwhile
    /// stay held for the page's field (`NewTabInputCoordinator`).
    func pageDidAppear() {
        guard !appearedThisTurn else { return }
        appearedThisTurn = true
        AfterFrameCommit().run { [weak self] in
            self?.appearedThisTurn = false
            self?.grantPendingFocusIfShown()
        }
    }
}
