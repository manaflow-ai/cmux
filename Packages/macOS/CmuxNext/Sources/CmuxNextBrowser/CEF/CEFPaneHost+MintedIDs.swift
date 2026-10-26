import Foundation

/// Host mode with ids cmux mints (task 019 of plans/cmux-next/chrome-parity/p01-process.md):
/// `create_window` and `tab_add` are posts to the Chromium Host, `tab_add` and `tab_duplicate`
/// return the id cmux minted at once, and the browser's AFTER_CREATED comes in a later batch. In
/// process both calls build in Chromium on the main thread, so a shown tab gets its browser after
/// the frame committed (PL-cef-tab).
extension CEFPaneHost {
    /// True for a host that maps the ids cmux mints (``CEFHostStart/mapsClientIDs``): a tab asks for
    /// its browser in the turn that shows it, and the host's shim makes the profile's directory.
    var createsBrowsersAtOnce: Bool { runtime.hostStart?.mapsClientIDs == true }

    /// Host mode before the host maps cmux's ids: a browser cmux mints there names nothing.
    var mintsUnmappedIDs: Bool { runtime.hostStart.map { !$0.mapsClientIDs } ?? false }

    /// The host refused this pane's `create_window` (CREATE_FAILED; the call returned 1 once sent).
    /// As after its 0 in process: no window, and its tab and the tabs waiting to join it show the failure.
    func windowCreationFailed(request: Int32) {
        guard case .creating(let expected) = window, expected == request else { return }
        window = .none
        for tab in tabs where tab.browserID == nil && tab.isCreationPending { tab.creationFailed() }
    }
}

/// The host refused a browser cmux minted (CREATE_FAILED). Not a close: the tab stays, with no
/// browser and the failure page, as after the shim's 0 return in process (`addToWindow`,
/// `ensureCreated`); showing it again asks for a browser again. A call cmux made on the refused id
/// is answered by the host (its id names no browser there), so only a quit still counts it.
struct CEFCreateFailure {
    /// The minted id.
    let browser: Int32
    /// `create_window`'s request, or 0 for `tab_add` and `tab_duplicate`.
    let request: Int32

    func apply(to runtime: CEFRuntime) {
        if request != 0, let host = runtime.pendingWindows.removeValue(forKey: request) {
            host.windowCreationFailed(request: request)
        } else if let tab = runtime.tabsByBrowser.removeValue(forKey: browser) {
            tab.creationFailed()
        }
        // A quit waits until every browser and window request has ended (`CEFRuntime.shutdown`).
        runtime.shutdownSequence?.browserClosed(remaining: runtime.tabsByBrowser.count + runtime.pendingWindows.count)
        runtime.shutdownProgressed()
    }
}
