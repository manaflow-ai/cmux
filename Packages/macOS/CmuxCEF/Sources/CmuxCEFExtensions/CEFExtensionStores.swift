public import CmuxBrowser
public import CmuxCEF
public import Foundation

/// The extension mirrors of the Chromium engine, one per cmux browser
/// profile, and the Chromium pages that show extension actions.
///
/// Pages register here; a profile's store anchors its calls on any live page
/// of that profile. The fork's extension events refresh the affected stores
/// and pages. Construct one at app start and inject it into the Chromium
/// page provider.
@MainActor
public final class CEFExtensionStores {
    private let calls: any CEFExtensionCalls
    private var stores: [UUID: BrowserExtensionStore] = [:]
    private var pages: [ObjectIdentifier: WeakPage] = [:]
    private var observerToken: UUID?

    /// Creates the stores.
    ///
    /// - Parameter calls: The fork's extension calls.
    public init(calls: any CEFExtensionCalls) {
        self.calls = calls
    }

    /// The extension mirror of `profile`, created on first use.
    public func store(for profile: UUID) -> BrowserExtensionStore {
        if let store = stores[profile] { return store }
        let backend = CEFExtensionBackend(calls: calls) { [weak self] in self?.anchor(profile: profile) }
        let store = BrowserExtensionStore(profileID: profile, backend: backend)
        stores[profile] = store
        return store
    }

    /// Starts tracking a page (its actions refresh on extension events).
    public func register(_ page: CEFExtensionPageSupport) {
        pages[ObjectIdentifier(page)] = WeakPage(page: page)
    }

    /// Stops tracking a page.
    public func unregister(_ page: CEFExtensionPageSupport) {
        pages[ObjectIdentifier(page)] = nil
    }

    /// Routes the runtime's fork tab events to ``handle(_:browser:window:)``.
    ///
    /// - Parameter runtime: The process's Chromium runtime.
    public func observe(_ runtime: CEFRuntime) {
        guard observerToken == nil else { return }
        observerToken = runtime.addEventObserver { [weak self] event in
            guard case .tab(let kind, let browser, let window, _) = event else { return }
            self?.handle(kind, browser: browser, window: window)
        }
    }

    /// Refreshes what a fork tab event changed.
    ///
    /// Actions changed: the pages of that Chromium window re-read their
    /// actions, and the profile stores refresh (a pin changes both lists).
    /// Extensions changed (installed, removed, enabled, disabled): every
    /// store of the affected profiles refreshes. A popup closed: the window's
    /// pages forget their open popup.
    public func handle(_ kind: CEFForkTabEvent, browser: Int32, window: Int32) {
        let live = livePages()
        let affected = live.filter { $0.cefBrowserID == browser || (window != 0 && $0.windowID == window) }
        switch kind {
        case .extensionActionsChanged, .inserted:
            affected.forEach { $0.refreshActions() }
            if kind == .extensionActionsChanged { refreshStores(for: affected, all: affected.isEmpty) }
        case .extensionsChanged:
            refreshStores(for: affected, all: true)
            live.forEach { $0.refreshActions() }
        case .extensionPopupClosed:
            affected.forEach { $0.popupClosed() }
        default:
            break
        }
    }

    private func refreshStores(for affected: [CEFExtensionPageSupport], all: Bool) {
        let profiles = all ? Set(stores.keys) : Set(affected.map(\.profileID))
        for profile in profiles { stores[profile]?.refresh() }
    }

    /// Any live browser id of `profile`.
    func anchor(profile: UUID) -> Int32? {
        livePages().lazy.filter { $0.profileID == profile }.compactMap(\.cefBrowserID).first
    }

    private func livePages() -> [CEFExtensionPageSupport] {
        pages = pages.filter { $0.value.page != nil }
        return pages.values.compactMap(\.page)
    }

    /// The fork's window id of a browser (0 when unknown).
    func windowID(browser: Int32) -> Int32 { calls.windowID(browser: browser) }

    /// The calls pages use for their own actions.
    var extensionCalls: any CEFExtensionCalls { calls }

    private struct WeakPage {
        weak var page: CEFExtensionPageSupport?
    }
}
