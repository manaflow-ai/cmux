import AppKit
import Foundation

/// One Chromium `Browser` (tabbed window) per cmux pane and profile
/// (browser.md, Decision 1). The first CEF tab shown in the pane creates the
/// window in `hostView`; later tabs join it with `cmux_tab_add`, so
/// extensions see one Chrome window with N tabs. Showing a tab reparents the
/// shared `hostView` into that tab's content view and activates the tab; the
/// fork's tracker follows the reparent and clips the page to the visible
/// part of the view.
final class CEFPaneHost {
    let key: CEFPaneKey
    let hostView = CEFHostView()
    private unowned let runtime: CEFRuntime

    private enum WindowState: Equatable {
        case none
        case creating(request: Int32)
        case live(window: Int32)
    }

    private var window: WindowState = .none
    /// Tabs of this host, in creation order.
    private(set) var tabs: [CEFTab] = []
    /// The tab whose creation created the window.
    private var windowTab: CEFTab?
    /// The tab currently shown in `hostView`.
    private(set) weak var visibleTab: CEFTab?
    /// The browser this host last made Chromium's active tab (its own
    /// `cmux_tab_activate`, or the window's first tab). Chromium echoes an
    /// activation for it, often after the user has moved on.
    private(set) var lastActivated: Int32?

    init(key: CEFPaneKey, runtime: CEFRuntime) {
        self.key = key
        self.runtime = runtime
    }

    func add(_ tab: CEFTab) {
        tabs.append(tab)
    }

    func owns(window id: Int32) -> Bool {
        window == .live(window: id)
    }

    var isCreatingWindow: Bool {
        if case .creating = window { return true }
        return false
    }

    var isLive: Bool {
        if case .live = window { return true }
        return false
    }

    /// A browser of this window, to address it (cmux_tab_add, moves).
    var anchorBrowser: Int32? { tabs.lazy.compactMap(\.browserID).first }

    func containsBrowser(inWindow id: Int32) -> Bool {
        guard let shim = runtime.shim else { return false }
        return tabs.contains { $0.browserID.map { shim.tabWindowID($0) == id } ?? false }
    }

    /// Called when a tab's content view enters a window: show that tab.
    func present(_ tab: CEFTab, in container: NSView) {
        BrowserLifecycleTrace.record(tab.id, "host-present hidden=\(hostView.isHidden) created=\(tab.browserID != nil)")
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
        runtime.lastShownHost = self
        ensureCreated(tab)
        if let browser = tab.browserID {
            lastActivated = browser
            _ = runtime.shim?.tabActivate(browser)
            hostView.postGeometryChange()
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
        BrowserLifecycleTrace.record(tab.id, "host-conceal wasShown=\(visibleTab === tab)")
        guard visibleTab === tab else { return }
        visibleTab = nil
    }

    // MARK: Creation

    private func ensureCreated(_ tab: CEFTab) {
        guard tab.browserID == nil, tab.isCreationPending == false, let shim = runtime.shim else { return }
        switch window {
        case .none:
            let request = runtime.makeRequestToken()
            let size = hostView.bounds.size
            // CEF refuses a request context whose cache directory is missing.
            let cachePath = runtime.storage.cachePath(for: key.profile)
            try? FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)
            tab.isCreationPending = true
            windowTab = tab
            window = .creating(request: request)
            runtime.pendingWindows[request] = self
            // The theme may have changed since CEF started.
            shim.setBackgroundColor(PageBackground.themeARGB)
            let started = shim.createWindow(
                request, Unmanaged.passUnretained(hostView).toOpaque(),
                max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32,
                tab.initialURLString, cachePath.path
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
        if let visible = visibleTab, let id = visible.browserID {
            lastActivated = id
            _ = runtime.shim?.tabActivate(id)
        }
        refreshExtensionActions()
        runtime.extensionStore(for: key.profile).refresh()
        runtime.windowBecameLive(self)
    }

    /// A tab Chromium opened in this window (target=_blank, window.open,
    /// chrome.tabs.create, a window request the fork placed here). It is
    /// handed to the host app through the opener's delegate as `.adoptTab`,
    /// which keeps `window.opener`.
    func adoptChromiumTab(browser: Int32, disposition: BrowserNewTabDisposition = .foregroundTab) {
        let opener = visibleTab ?? tabs.last
        let tab = CEFTab(id: .random(), profile: key.profile, host: self, runtime: runtime)
        tab.isCreationPending = true
        add(tab)
        runtime.register(tab, browser: browser)
        tab.inheritDelegates(from: opener)
        opener?.emit(.adoptTab(tab, disposition))
    }

    func removed(_ tab: CEFTab) {
        tabs.removeAll { $0 === tab }
        if windowTab === tab { windowTab = nil }
        if visibleTab === tab { visibleTab = nil }
        if tabs.isEmpty {
            window = .none
            hostView.removeFromSuperview()
        }
    }

    func refreshExtensionActions() {
        for tab in tabs { tab.refreshExtensionActions() }
    }
}
