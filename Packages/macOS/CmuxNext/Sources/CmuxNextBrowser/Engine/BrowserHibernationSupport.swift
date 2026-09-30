public import AppKit

/// Pages that can save their history for hibernation (Chrome's Memory
/// Saver): the App closes the page and later recreates it from the state.
public protocol BrowserHibernationSource: AnyObject {
    /// The history to recreate this page with, or nil when this engine or
    /// build cannot restore it (then the page is not hibernated, because a
    /// reload into a blank history would lose back/forward).
    @MainActor func hibernationState() -> BrowserRestoreState?
    /// True when this engine and build can restore a saved history.
    @MainActor var supportsHibernation: Bool { get }
}

extension WebKitTab: BrowserHibernationSource {
    public var supportsHibernation: Bool { true }

    public func hibernationState() -> BrowserRestoreState? {
        (webView.interactionState as? Data).map(BrowserRestoreState.webKit)
    }

    /// Restores a saved history (and scroll position) into this fresh tab.
    /// Returns false when WebKit rejected it; the caller then loads the URL.
    @discardableResult
    public func restore(_ state: BrowserRestoreState) -> Bool {
        guard case .webKit(let data) = state, !data.isEmpty else { return false }
        // WebKit loads the restored current item itself; loading the URL on
        // top would add a history entry.
        webView.interactionState = data
        return true
    }
}

extension CEFTab: BrowserHibernationSource {
    public var supportsHibernation: Bool { runtime.shim?.navigationRestoreSupported() == 1 }

    public func hibernationState() -> BrowserRestoreState? {
        guard let browserID, let shim = runtime.shim, shim.navigationRestoreSupported() == 1,
              let raw = shim.tabNavigationState(browserID) else { return nil }
        defer { shim.free(raw) }
        return .chromium(String(cString: raw))
    }
}
