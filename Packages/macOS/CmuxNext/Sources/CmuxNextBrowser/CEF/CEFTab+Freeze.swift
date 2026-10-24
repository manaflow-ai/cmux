import Foundation

/// A hidden Chromium page frozen through the page lifecycle: its timers, tasks and rendering stop
/// until it thaws. On cmux14 this cut a hidden renderer's energy by about 90 %.
///
/// From fork API 29 through `WebContents::SetPageFrozen` (`cmux_shim_tab_set_frozen`), which opens
/// no DevTools session, so the tab's renderer stays shareable; it freezes hidden pages only.
/// Before, through DevTools `Page.setWebLifecycleState`.
extension CEFTab: BrowserFreezing {
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool {
        guard let browserID, !isClosed, let shim = runtime.shim else { return false }
        if runtime.forkFeatures.rendererPaths, let setFrozen = shim.tabSetFrozen { return setFrozen(browserID, frozen ? 1 : 0) == 1 }
        // Sent now, not from a Task: an agent call queued right after a thaw must not reach a frozen page.
        // No one waits for the reply (the runtime drops a reply without a waiter).
        return shim.devToolsCall(browserID, "Page.setWebLifecycleState", CEFDevToolsResult.params(["state": frozen ? "frozen" : "active"])) != 0
    }
}
