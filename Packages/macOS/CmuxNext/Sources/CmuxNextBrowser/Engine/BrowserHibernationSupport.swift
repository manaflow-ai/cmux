public import AppKit

/// Pages that can save their history for hibernation: the App closes the
/// page and later recreates it from the state.
public protocol BrowserHibernationSource: AnyObject {
    /// The history to recreate this page with, or nil when this engine or
    /// build cannot restore it (then the page is not hibernated, because a
    /// reload into a blank history would lose back/forward).
    @MainActor func hibernationState() -> BrowserRestoreState?
    /// True when this engine and build can restore a saved history.
    @MainActor var supportsHibernation: Bool { get }
    /// The shown document came from a form submission (a POST; the saved
    /// session's current entry carries `formPost`): waking would load it
    /// again, so the page never hibernates (BR-R1).
    @MainActor var showsFormSubmission: Bool { get }
    /// The shown site may show notifications (its notifications permission is Allow): a
    /// hibernated page shows none, so the idle timeout keeps it (Chrome's kNotificationsEnabled).
    @MainActor var allowsNotifications: Bool { get }
}

extension WebKitTab: BrowserHibernationSource {
    public var supportsHibernation: Bool { true }
    public var showsFormSubmission: Bool { restored.showsFormSubmission }

    /// WebKit tabs show web notifications (`WebKitNotificationBridge`) when the site's stored answer is Allow.
    public var allowsNotifications: Bool {
        guard let url = state.url, let origin = PageInfoSite.origin(of: url) else { return false }
        return sitePermissions.setting(.notifications, for: origin) == .allow
    }

    public func hibernationState() -> BrowserRestoreState? {
        (webView.interactionState as? Data).map(BrowserRestoreState.webKit)
    }

    /// Restores a saved history (and scroll position) into this fresh tab.
    /// Returns false when WebKit rejected it; the caller then loads the URL.
    @discardableResult
    public func restore(_ state: BrowserRestoreState) -> Bool {
        guard case .webKit(let data) = state, !data.isEmpty else { return false }
        // WebKit loads the restored current item itself; loading the URL on
        // top would add a history entry. A form that item came from is not
        // sent again without the person (WebKitFormResubmission).
        formResubmission.restoring = true
        formResubmission.restoreData = data
        webView.interactionState = data
        return true
    }
}

extension CEFTab: BrowserHibernationSource {
    /// Fork API 10: `cmux_tab_restore_navigation` drops the new browser's
    /// pending chrome://ignore/ navigation and restores. API 7-9 refused
    /// every restore (verified on cef-154.0.28-cmux.7 and cmux.8), so a page
    /// there would wake with a blank history: it is not hibernated.
    static let navigationRestoreForkAPI: Int32 = 10

    public var supportsHibernation: Bool {
        guard let shim = runtime.shim else { return false }
        return shim.navigationRestoreSupported() == 1 && shim.forkAPIVersion() >= Self.navigationRestoreForkAPI
    }

    public var showsFormSubmission: Bool { restored.showsFormSubmission }

    /// Chromium tabs show no web notifications in cmux (`CEFSwitches`: disable-notifications).
    public var allowsNotifications: Bool { false }

    public func hibernationState() -> BrowserRestoreState? {
        guard supportsHibernation, let browserID, let shim = runtime.shim,
              let raw = shim.tabNavigationState(browserID) else { return nil }
        defer { shim.free(raw) }
        return .chromium(String(cString: raw))
    }
}

extension BrowserRestoreState {
    /// The back/forward history `page` can be recreated from (Duplicate Tab,
    /// Reopen Closed Tab): a hibernated page's saved state, else what a live
    /// page saves now.
    @MainActor public static func history(of page: any BrowserTab) -> BrowserRestoreState? {
        if let hibernated = page as? HibernatedBrowserTab { return hibernated.restoreState }
        return (page as? any BrowserHibernationSource)?.hibernationState()
    }
}
