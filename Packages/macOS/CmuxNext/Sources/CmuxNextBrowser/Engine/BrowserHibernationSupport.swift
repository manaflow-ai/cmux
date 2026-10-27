public import AppKit

/// Pages that can save their history for hibernation: the App closes the
/// page and later recreates it from the state.
///
/// Main actor as a whole, as every requirement is: a protocol that also refines a main-actor
/// protocol (`BrowserStreamedPage` over `BrowserWakeStandIn`) can then imply this conformance,
/// which an inferred isolated conformance of a main-actor page could not.
@MainActor public protocol BrowserHibernationSource: AnyObject {
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
              let state = shim.tabNavigationState(browserID) else { return nil }
        return .chromium(state)
    }
}

/// A cmux page in a browser tab (`cmux://history`, `cmux://bookmarks`, `cmux://vault`,
/// `cmux://screenshots`, `cmux://agent-activity`): cmux's own view, no site and no back/forward
/// history. It hibernates as a web page does, to a `HibernatedBrowserTab` showing its last
/// picture, and waking builds the page again at its address with the view state it saved. Chrome
/// keeps a discarded tab's navigation entries with their scroll and form state
/// (content/public/browser/navigation_entry.h) and loads the tab again when it shows
/// (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc).
public protocol BrowserAppPage: BrowserHibernationSource {
    /// The page's `cmux://` address.
    @MainActor var pageAddress: URL { get }
    /// The page draws its content in its first frame (a native view): its wake needs no picture
    /// over it. A page in a web engine paints after its document loads, so its wake shows the
    /// stand-in (`BrowserWakeStandIn`) or counts as uncovered.
    @MainActor var drawsInFirstFrame: Bool { get }
    /// The page's address and what it shows besides: search text, selection, scroll. Asked right
    /// before the page goes; a page in a web engine reads its document (bounded).
    @MainActor func saveViewState() async -> BrowserAppPageState
    /// Puts `state` back on this page, built again after a hibernation.
    @MainActor func restoreViewState(_ state: BrowserAppPageState)
}

extension BrowserAppPage {
    /// A cmux page can be built again; the App's `memoryDiscardPageTabs` decides whether it hibernates.
    public var supportsHibernation: Bool { true }
    /// A cmux page is never a form submission's result.
    public var showsFormSubmission: Bool { false }
    /// A cmux page shows no web notifications.
    public var allowsNotifications: Bool { false }

    /// Its address only: the hibernation asks ``saveViewState()`` for the rest.
    public func hibernationState() -> BrowserRestoreState? { .appPage(BrowserAppPageState(url: pageAddress)) }
}

/// What a hibernated cmux page (`BrowserAppPage`) gets back when it is built again: the same
/// fields as an internal page's view state (`ContentViewState`, p07-memory 022).
public nonisolated struct BrowserAppPageState: Hashable, Sendable {
    /// A scroll position, in the document's coordinates.
    public nonisolated struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The page's `cmux://` address.
    public var url: URL
    /// The visible origin of its main list or document.
    public var scroll: Point?
    /// The text of its search or filter field.
    public var search: String?
    /// What it had selected (a folder, a row, a session).
    public var selection: String?

    public init(url: URL, scroll: Point? = nil, search: String? = nil, selection: String? = nil) {
        self.url = url
        self.scroll = scroll
        self.search = search
        self.selection = selection
    }
}

extension BrowserRestoreState {
    /// The back/forward history `page` can be recreated from (Duplicate Tab,
    /// Reopen Closed Tab): a hibernated page's saved state, else what a live
    /// page saves now. A cmux page has none: it opens at its address.
    @MainActor public static func history(of page: any BrowserTab) -> BrowserRestoreState? {
        let saved = (page as? HibernatedBrowserTab)?.restoreState ?? (page as? any BrowserHibernationSource)?.hibernationState()
        if case .appPage? = saved { return nil }
        return saved
    }
}
