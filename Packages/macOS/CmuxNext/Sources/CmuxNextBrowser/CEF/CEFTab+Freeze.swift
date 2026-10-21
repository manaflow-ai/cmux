import Foundation

/// A hidden Chromium page frozen through the page lifecycle
/// (`Page.setWebLifecycleState`): its timers, tasks and rendering stop until
/// it thaws. On cmux14 this cut a hidden renderer's energy by about 90 %.
extension CEFTab: BrowserFreezing {
    public func setFrozen(_ frozen: Bool) {
        guard let browserID, !isClosed, let shim = runtime.shim else { return }
        // Sent now, not from a Task: an agent call queued right after a thaw must not reach a frozen page.
        // No one waits for the reply (the runtime drops a reply without a waiter).
        _ = shim.devToolsCall(browserID, "Page.setWebLifecycleState", CEFDevToolsResult.params(["state": frozen ? "frozen" : "active"]))
    }
}
