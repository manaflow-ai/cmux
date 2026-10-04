import AppKit
import Foundation

/// One Chromium `Browser` (tabbed window) per cmux pane and profile
/// (browser.md, Decision 1). The first CEF tab shown in the pane creates the
/// window in `hostView`; later tabs join it with `cmux_tab_add`, so
/// extensions see one Chromium window with N tabs. Showing a tab reparents the
/// shared `hostView` into that tab's content view and activates the tab; the
/// fork's tracker follows the reparent and clips the page to the visible
/// part of the view.
final class CEFPaneHost {
    let key: CEFPaneKey
    let hostView = CEFHostView()
    unowned let runtime: CEFRuntime

    enum WindowState: Equatable {
        case none
        case creating(request: Int32)
        case live(window: Int32)
    }

    var window: WindowState = .none
    /// Tabs of this host, in creation order.
    private(set) var tabs: [CEFTab] = []
    /// The tab whose creation created the window.
    private var windowTab: CEFTab?
    /// The tab currently shown in `hostView`.
    private(set) weak var visibleTab: CEFTab?
    /// The browser this host last made Chromium's active tab (its own
    /// `cmux_tab_activate`, or the window's first tab). Chromium echoes an
    /// activation for it, often after the user has moved on.
    var lastActivated: Int32?
    /// A popup host's about:blank browser that created its Chromium window;
    /// it closes once the popup moved in (`CEFPaneHost+Popups`).
    var placeholder: CEFTab?
    /// An extension's popup window (chrome.windows.create type popup, fork
    /// API 11): the hidden Chromium window this popup host attaches to its
    /// view when the panel first shows it (`CEFPaneHost+PopupWindows`).
    var popupWindow: Int32?

    let lifecycleTrace: BrowserLifecycleTrace
    let contextMenus: BrowserContextMenuBuilder

    init(key: CEFPaneKey, runtime: CEFRuntime, lifecycleTrace: BrowserLifecycleTrace = .shared,
         contextMenus: BrowserContextMenuBuilder = .shared) {
        self.key = key
        self.runtime = runtime
        self.lifecycleTrace = lifecycleTrace
        self.contextMenus = contextMenus
    }

    func add(_ tab: CEFTab) {
        tabs.append(tab)
    }

    /// True when Chromium window `id` is this host's (never window 0).
    func owns(window id: Int32) -> Bool {
        let recorded: Int32? = if case .live(let window) = window { window } else { nil }
        return CEFWindowIdentity.owns(recorded: recorded, reported: id) { liveWindowIDs }
    }

    /// The windows this host's tabs are in now.
    private var liveWindowIDs: [Int32] {
        guard let shim = runtime.shim else { return [] }
        return tabs.compactMap { tab in tab.awaitsWindowMove ? nil : tab.browserID.map { shim.tabWindowID($0) } }
    }

    var isCreatingWindow: Bool {
        if case .creating = window { return true }
        return false
    }

    var isLive: Bool {
        if case .live = window { return true }
        return false
    }

    /// A browser of this window, to address it (cmux_tab_add, moves). A
    /// popup still in its opener's window is not one.
    var anchorBrowser: Int32? { tabs.lazy.filter { !$0.awaitsWindowMove }.compactMap(\.browserID).first }

    /// Called when a tab's content view enters a window: show that tab.
    func present(_ tab: CEFTab, in container: NSView) {
        lifecycleTrace.record(tab.id, "host-present hidden=\(hostView.isHidden) created=\(tab.browserID != nil)")
        if hostView.superview !== container {
            hostView.removeFromSuperview()
            hostView.frame = container.bounds
            // The tab's content view lays it out (page frame beside a docked DevTools).
            hostView.autoresizingMask = []
            container.addSubview(hostView, positioned: .below, relativeTo: nil)
        }
        // The content lifecycle decides visibility; entering a window does
        // not override a hide it applied (a pane parked off screen).
        hostView.isHidden = tab.isContentHidden
        visibleTab = tab
        // Tabs from windows cmux does not host go to a pane, never a panel.
        if !isPopupHost { runtime.lastShownHost = self }
        if attachPopupWindowIfNeeded(tab) { return }
        ensureCreated(tab)
        if tab.awaitsWindowMove {
            // Still in its opener's window: activating it there would show
            // it in the opener's pane. It moves into this host's window.
            ensureOwnWindow(for: tab)
        } else if let browser = tab.browserID {
            lastActivated = browser
            _ = runtime.shim?.tabActivate(browser)
            hostView.postGeometryChange()
            // A window-wide side panel stays open across tabs: no event.
            tab.scheduleSidePanelRefresh()
        }
    }

    /// True when Chromium activating `tab` is a choice made inside Chromium
    /// (an extension switching the window's tab), not the echo of this
    /// host's own activation or tab creation: only then may the App select
    /// the tab. A window with one tab has nothing to switch.
    func isForeignActivation(of tab: CEFTab) -> Bool {
        guard tabs.count > 1, visibleTab !== tab, let browser = tab.browserID else { return false }
        return browser != lastActivated
    }

    /// Called when a tab's content view leaves its window.
    func conceal(_ tab: CEFTab) {
        lifecycleTrace.record(tab.id, "host-conceal wasShown=\(visibleTab === tab)")
        guard visibleTab === tab else { return }
        visibleTab = nil
    }

    // MARK: Creation

    func ensureCreated(_ tab: CEFTab) {
        guard tab.browserID == nil, tab.isCreationPending == false, let shim = runtime.shim else { return }
        switch window {
        case .none:
            let request = runtime.makeRequestToken()
            let size = hostView.bounds.size
            let contextKey = runtime.contextKey(for: key)
            if key.offTheRecord {
                // An in-memory profile: no directory, released when the
                // incognito session ends.
                runtime.offTheRecordContexts[key.profile, default: []].insert(contextKey)
            } else {
                // CEF refuses a request context whose cache directory is missing.
                try? FileManager.default.createDirectory(at: URL(filePath: contextKey), withIntermediateDirectories: true)
            }
            // A remote-localhost store: its context must use the proxy before
            // its first request, or localhost would reach this Mac.
            if let store = tab.machineStore,
               shim.setContextProxy(contextKey, Int32(store.proxyPort)) != 1
                || shim.contextProxyState(contextKey) < 0 {
                tab.creationFailed()
                return
            }
            tab.isCreationPending = true
            windowTab = tab
            window = .creating(request: request)
            runtime.pendingWindows[request] = self
            // The first frame takes this pane's theme scope (room,
            // workspace), which may differ from the app theme.
            shim.setBackgroundColor(PageBackground.themeARGB(in: hostView))
            let started = shim.createWindow(
                request, Unmanaged.passUnretained(hostView).toOpaque(),
                max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32,
                tab.initialURLString, contextKey
            )
            if started != 1 {
                runtime.pendingWindows[request] = nil
                window = .none
                tab.creationFailed()
            }
        case .creating:
            // Joins the window once it exists (windowCreated).
            tab.isCreationPending = true
        case .live:
            addToWindow(tab)
        }
    }

    private func addToWindow(_ tab: CEFTab) {
        guard let shim = runtime.shim, let anchor = tabs.lazy.compactMap(\.browserID).first else {
            window = .none
            return
        }
        tab.isCreationPending = true
        runtime.tabBeingAdded = tab
        let browser = shim.tabAdd(anchor, tab.initialURLString, -1, visibleTab === tab ? 1 : 0)
        runtime.tabBeingAdded = nil
        if browser == 0 {
            tab.creationFailed()
        } else if tab.browserID == nil {
            runtime.register(tab, browser: browser)
        }
    }

    func windowCreated(browser: Int32, request: Int32) {
        guard case .creating(let expected) = window, expected == request, let tab = windowTab else { return }
        let windowID = runtime.shim?.tabWindowID(browser) ?? 0
        window = .live(window: windowID)
        lastActivated = browser
        runtime.register(tab, browser: browser)
        // Tabs shown or created while the window was being built.
        for waiting in tabs where waiting !== tab && waiting.browserID == nil && waiting.isCreationPending {
            waiting.isCreationPending = false
            addToWindow(waiting)
        }
        if let visible = visibleTab, !visible.awaitsWindowMove, let id = visible.browserID {
            lastActivated = id
            _ = runtime.shim?.tabActivate(id)
        }
        refreshExtensionActions()
        runtime.extensionStores.store(for: key.profile).refresh()
        runtime.orphans.windowBecameLive(self)
        if tabs.contains(where: \.awaitsWindowMove) {
            // Never inside OnAfterCreated (Chromium's tab insertion): moving
            // a tab between tab strips there would re-enter it.
            Task { @MainActor [weak self] in self?.movePopupsIn() }
        }
    }

    /// A tab Chromium opened in this window (target=_blank, window.open,
    /// chrome.tabs.create, a window request the fork placed here). It is
    /// handed to the host app through the opener's delegate as `.adoptTab`,
    /// which keeps `window.opener`.
    /// A `.popup` becomes a floating panel page with its own window
    /// (`adoptPopup`); `bounds` are its window features.
    func adoptChromiumTab(browser: Int32, disposition: BrowserNewTabDisposition = .foregroundTab, bounds: CGRect? = nil) {
        let opener = visibleTab ?? tabs.last
        if disposition == .popup { return adoptPopup(browser: browser, bounds: bounds, opener: opener) }
        let tab = CEFTab(id: .random(), profile: key.profile, host: self, runtime: runtime)
        // Same window, same store: a popup of a remote machine's localhost
        // page keeps its store and navigation guard.
        tab.machineStore = opener?.machineStore
        tab.navigationGuard = opener?.navigationGuard ?? .none
        tab.isCreationPending = true
        add(tab)
        runtime.register(tab, browser: browser)
        // Opened by a page: past a new tab's first paint (PageBackground).
        tab.reachedFirstRealPage()
        tab.inheritDelegates(from: opener)
        opener?.emit(.adoptTab(tab, disposition))
    }

    func removed(_ tab: CEFTab) {
        tabs.removeAll { $0 === tab }
        if windowTab === tab { windowTab = nil }
        if visibleTab === tab { visibleTab = nil }
        if placeholder === tab { placeholder = nil }
        if tabs.isEmpty {
            window = .none
            hostView.removeFromSuperview()
            if isPopupHost { runtime.hosts[key] = nil }
        }
    }

    func refreshExtensionActions() {
        for tab in tabs { tab.refreshExtensionActions() }
    }
}
