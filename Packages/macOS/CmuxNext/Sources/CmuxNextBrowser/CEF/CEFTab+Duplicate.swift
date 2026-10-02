import Foundation

/// A user-owned copy of a tab (fork API 16, `cmux_tab_duplicate`;
/// plans/cmux-next/feed.md section 10): the same profile, the back/forward
/// history (POST bodies dropped) and a sessionStorage snapshot, its own
/// BrowsingInstance, no opener, and password filling on (the agent mark
/// stays on the source). The fork adds the copy in the background to this
/// tab's pane window, and the pane adopts it like any tab Chromium adds
/// (OnAfterCreated runs inside the call). The caller shows or moves it.
extension CEFTab {
    static let duplicateForkAPI: Int32 = 16

    public var canDuplicate: Bool {
        browserID != nil && runtime.forkAPIVersion >= Self.duplicateForkAPI
    }

    /// The adopted copy, or nil: an older fork, a closed tab, or a tab with
    /// nothing committed yet.
    @discardableResult
    public func duplicate() -> CEFTab? {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= Self.duplicateForkAPI,
              let anchor = host.anchorBrowser else { return nil }
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
