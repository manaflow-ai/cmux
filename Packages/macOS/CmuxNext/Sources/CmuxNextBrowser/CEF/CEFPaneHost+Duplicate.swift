import Foundation

/// A user-owned copy of a tab of this pane (fork API 16,
/// `cmux_tab_duplicate`; plans/cmux-next/feed.md section 10): the same
/// profile, the back/forward history (request bodies dropped) and a
/// sessionStorage snapshot, its own BrowsingInstance, no opener, and password
/// filling on (the agent mark stays on the source). The fork adds the copy in
/// the background to this pane's window, and the pane adopts it like any tab
/// Chromium adds (OnAfterCreated runs inside the call). The caller shows or
/// moves it.
extension CEFPaneHost {
    static let duplicateForkAPI: Int32 = 16

    public func canDuplicate(_ tab: CEFTab) -> Bool {
        tab.browserID != nil && runtime.forkAPIVersion >= Self.duplicateForkAPI
    }

    /// The adopted copy of `tab`, or nil: an older fork, a closed tab, or a
    /// tab with nothing committed yet.
    @discardableResult
    public func duplicate(_ tab: CEFTab) -> CEFTab? {
        guard let browserID = tab.browserID, let shim = runtime.shim,
              runtime.forkAPIVersion >= Self.duplicateForkAPI, let anchor = anchorBrowser else { return nil }
        let window = shim.tabWindowID(anchor)
        if window != 0 {
            runtime.placements.record(window: window, CEFPlacement(disposition: .backgroundTab))
        }
        let copy = shim.tabDuplicate(browserID, anchor, -1)
        guard copy > 0 else {
            if window != 0 { runtime.placements.withdrawLast(window: window) }
            runtime.logger.notice("duplicate of browser \(browserID, privacy: .public) refused by the fork")
            return nil
        }
        return runtime.tabsByBrowser[copy]
    }
}
