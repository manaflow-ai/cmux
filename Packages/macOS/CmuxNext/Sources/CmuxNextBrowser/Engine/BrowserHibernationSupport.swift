public import AppKit
import CmuxNextWakeups

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
    /// A cmux page's address is no history: duplicating or reopening it opens its address.
    @MainActor public static func history(of page: any BrowserTab) -> BrowserRestoreState? {
        let state = (page as? HibernatedBrowserTab)?.restoreState ?? (page as? any BrowserHibernationSource)?.hibernationState()
        if case .page? = state { return nil }
        return state
    }
}

/// A page the App builds from a cmux address, with no engine history (a remote desktop, a remote
/// browser stream, a machine's browser tab). It hibernates to that address
/// (`BrowserRestoreState.page`): the discard closes the page, its stream and its decoder, the
/// placeholder keeps its last frame, and showing the tab builds the page again, which connects.
/// Chrome's discard does the same for any tab (`TabLifecycleUnit::Discard` in
/// chrome/browser/resource_coordinator/tab_lifecycle_unit.cc closes the WebContents and keeps the
/// navigation entry to reload from).
public protocol BrowserAddressPage: BrowserTab, BrowserHibernationSource {
    /// The address the App builds this page from again; nil while it cannot be built again with
    /// the same result (then it is never discarded).
    @MainActor var wakeAddress: URL? { get }
}

extension BrowserAddressPage {
    public var supportsHibernation: Bool { wakeAddress != nil }
    /// No form posts: the page is no web document.
    public var showsFormSubmission: Bool { false }
    /// No web notifications: the page is no web document.
    public var allowsNotifications: Bool { false }
    public func hibernationState() -> BrowserRestoreState? { wakeAddress.map(BrowserRestoreState.page) }
}

/// A woken page's last frame over its view until the page presents its own first frame
/// (`BrowserWakeStandIn` for pages with no engine paint signal, such as a remote stream). The
/// page removes it on that frame; the cap and a close remove it too.
@MainActor public final class BrowserWakeCover {
    private var view: NSView?
    private var cap: DemandTimer?

    public init() {}

    /// The picture covers the page now.
    public var isShown: Bool { view != nil }

    /// Covers `host` with `picture`, above its subview `sibling` (nil: above every subview), until
    /// `remove()` or until `cap` passes on `clock`.
    public func show(_ picture: CGImage, decoded: Bool, in host: NSView, above sibling: NSView?, cap: Duration,
                     clock: any Clock<Duration>) {
        remove()
        // Pixels already decoded cover the page from the swap's first frame.
        let cover = decoded ? BrowserPictureView(decoded: picture) : BrowserPictureView(picture: { picture })
        cover.frame = host.bounds
        cover.autoresizingMask = [.width, .height]
        host.addSubview(cover, positioned: .above, relativeTo: sibling)
        view = cover
        let timer = DemandTimer(owner: "BrowserWakeCover", clock: clock)
        // Justified delay: the cap of a stand-in, not a poll; the first frame or a close cancels it.
        timer.schedule(after: cap) { @MainActor [weak self, weak cover] in
            guard let self, let cover, self.view === cover else { return }
            self.remove()
        }
        self.cap = timer
    }

    public func remove() {
        cap?.cancel()
        cap = nil
        view?.removeFromSuperview()
        view = nil
    }
}
