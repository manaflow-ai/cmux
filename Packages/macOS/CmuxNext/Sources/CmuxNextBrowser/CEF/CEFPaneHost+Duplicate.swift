import Foundation

/// A user-owned copy of a tab of this pane (fork API 16,
/// `cmux_tab_duplicate`; plans/cmux-next/feed.md section 10): the same
/// profile, the back/forward history (request bodies dropped) and a
/// sessionStorage snapshot, its own BrowsingInstance, no opener, and password
/// filling on (the agent mark stays on the source). The fork adds the copy in
/// the background to this pane's window. The pane makes the copy's tab before
/// the call, as `addToWindow` does, so the copy's OnAfterCreated completes it:
/// inside the call in process, in a later event batch in host mode, where the
/// call returns the browser id cmux minted (task 019 of
/// plans/cmux-next/chrome-parity/p01-process.md). The source announces it as
/// an adopted background tab; the caller shows or moves it.
extension CEFPaneHost {
    static let duplicateForkAPI: Int32 = 16

    /// The copy of `tab`, or nil: an older fork, a closed tab, a tab with
    /// nothing committed yet, or a host that does not map minted ids yet. A
    /// host that refuses the copy later sends CREATE_FAILED: the copy stays,
    /// with the failure page (`CEFRuntime.browserCreationFailed`).
    @discardableResult
    public func duplicate(_ tab: CEFTab) -> CEFTab? {
        guard let browserID = tab.browserID, runtime.acceptsNewBrowsers, !mintsUnmappedIDs, let shim = runtime.shim,
              runtime.forkAPIVersion >= Self.duplicateForkAPI, let anchor = anchorBrowser else { return nil }
        let copy = CEFTab(id: .random(), profile: key.profile, host: self, runtime: runtime)
        // Same window, same store: a copy of a remote machine's localhost page
        // keeps its store and navigation guard.
        copy.machineStore = tab.machineStore
        copy.navigationGuard = tab.navigationGuard
        copy.isCreationPending = true
        runtime.tabBeingAdded = copy
        let browser = shim.tabDuplicate(browserID, anchor, -1)
        runtime.tabBeingAdded = nil
        guard browser > 0 else {
            runtime.logger.notice("duplicate of browser \(browserID, privacy: .public) refused by the fork")
            return nil
        }
        add(copy)
        if copy.browserID == nil { runtime.register(copy, browser: browser) }
        // A copy of a committed page: past a new tab's first paint
        // (PageBackground), its page area is its own.
        copy.reachedFirstRealPage(settled: true)
        copy.inheritDelegates(from: tab)
        tab.emit(.adoptTab(copy, .backgroundTab))
        return copy
    }
}
