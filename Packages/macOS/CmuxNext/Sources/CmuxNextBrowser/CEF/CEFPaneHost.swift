import AppKit
import Foundation
import CmuxNextWakeups

/// One Chromium `Browser` (tabbed window) per cmux pane and profile
/// (browser.md, Decision 1). The first CEF tab shown in the pane creates the
/// window in `hostView`; later tabs join it with `cmux_tab_add`, so
/// extensions see one Chromium window with N tabs. Showing a tab reparents the
/// shared `hostView` into that tab's content view and activates the tab; the
/// fork's tracker follows the reparent and clips the page to the visible
/// part of the view.
final class CEFPaneHost {
    /// Changes only when a pane takes the spare window (`rekey`, CEFSpareWindow).
    var key: CEFPaneKey
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
    /// The placeholder's page is frozen as soon as its browser exists (the spare window, `CEFSpareWindow`):
    /// it is never shown, so Chromium never learns it is hidden and would run its frames and timers.
    var freezesPlaceholder = false
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
        hostView.liveResizeWillStart = { [weak self] in self?.visibleTab?.samplePageBackdrop() }
        hostView.fileDrag.target = { [weak self] in self?.visibleTab }
    }

    /// The viewport of a tab no pane has shown (Playwright's default page
    /// size, the WebKit render window's too).
    static let hiddenTabViewport = NSSize(width: 1280, height: 800)

    /// The size a new Chromium window starts at: the host view's, or the
    /// hidden-tab viewport when the view was never laid out (empty bounds
    /// gave a 1x1 window, so the page had no viewport).
    static func creationSize(for bounds: NSSize) -> NSSize {
        bounds.width >= 1 && bounds.height >= 1 ? bounds : hiddenTabViewport
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

    /// Runs a block at the end of this run-loop turn (`CEFLayerHosting.atEndOfTurn`); tests run it when they choose.
    var endOfTurn: CEFLayerHosting.Scheduler = { CEFLayerHosting.atEndOfTurn($0) }
    /// Whether a host visibility pass is queued for this run-loop turn.
    private var hostVisibilityPending = false
    /// Tabs shown before their browser existed, created once the frame committed (`createAfterCommit`).
    private(set) var deferredCreations: [WeakCEFTab] = []

    /// The host view's visibility is derived: hidden unless the shown tab is
    /// not concealed. A conceal queues one pass for the end of this run-loop
    /// turn (before the frame commits), so a same-pane switch, which conceals
    /// the old tab and presents the new one in the same turn, never takes the
    /// page window off screen (cx-asb1: Chromium then saw a window hide/show
    /// instead of a tab switch, about 100 ms late under load).
    func setNeedsHostVisibility() {
        guard !hostVisibilityPending else { return }
        hostVisibilityPending = true
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            // main-proof: a CFRunLoopGetMain() block runs on the main thread
            MainActor.assumeIsolated { self?.applyHostVisibility() }
        }
        CFRunLoopWakeUp(main)
    }

    private func applyHostVisibility() {
        hostVisibilityPending = false
        let hidden = visibleTab.map(\.isContentHidden) ?? true
        if hostView.isHidden != hidden { hostView.isHidden = hidden }
    }

    /// Called when a tab's content view enters a window: show that tab.
    func present(_ tab: CEFTab, in container: NSView) {
        lifecycleTrace.record(tab.id, "host-present hidden=\(hostView.isHidden) created=\(tab.browserID != nil)")
        if hostView.superview !== container {
            // A direct addSubview moves the view without taking it out of
            // the window: the page's child window is not re-added (about
            // 3 ms of window ordering on each tab switch).
            hostView.frame = container.bounds
            // The tab's content view lays it out (page frame beside a docked DevTools).
            hostView.autoresizingMask = []
            container.addSubview(hostView, positioned: .below, relativeTo: nil)
        }
        // The content lifecycle decides visibility; entering a window does
        // not override a hide it applied (a pane parked off screen).
        hostView.isHidden = tab.isContentHidden
        visibleTab = tab
        tab.applyHostBackdrop()
        // Tabs from windows cmux does not host go to a pane, never a panel.
        if !isPopupHost { runtime.lastShownHost = self }
        if attachPopupWindowIfNeeded(tab) { return }
        // A tab shown before its browser exists (a new tab, a hibernated one waking) gets it once
        // this turn's frame is committed: building or joining a Chromium window holds the main
        // thread (`create_window`, `tab_add`), and the tab's toolbar and themed page area must be
        // on screen in the frame of the key that asked for it (PL-cef-tab: < 10 ms).
        if tab.browserID == nil, !tab.awaitsWindowMove { return createAfterCommit(tab) }
        ensureCreated(tab)
        if tab.awaitsWindowMove {
            // Still in its opener's window: activating it there would show
            // it in the opener's pane. It moves into this host's window.
            ensureOwnWindow(for: tab)
        } else {
            showBrowser(of: tab)
            tab.grantPendingFocusIfShown()
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
        // The tab view can leave its window before the content lifecycle's visibility callback.
        // Queue the derived host pass here too so callback ordering cannot leave the Chromium child
        // window visible after the page is parked.
        setNeedsHostVisibility()
    }

    // MARK: Creation

    /// Creates `tab`'s browser after the current run-loop pass committed its frame: one main
    /// run loop observer after every other one of the pass (Core Animation's commit runs before
    /// it), once. The run loop is woken after, so what the creation changed commits in the next pass.
    private func createAfterCommit(_ tab: CEFTab) {
        guard !deferredCreations.contains(where: { $0.tab === tab }) else { return }
        deferredCreations.append(WeakCEFTab(tab))
        guard deferredCreations.count == 1 else { return }
        AfterFrameCommit().run { [weak self] in self?.createDeferred() }
    }

    /// Makes the browsers of the tabs shown before theirs existed (the observer of `createAfterCommit`; tests call it).
    func createDeferred() {
        let waiting = deferredCreations.compactMap(\.tab)
        deferredCreations.removeAll()
        for tab in waiting where !tab.isClosed && tabs.contains(where: { $0 === tab }) {
            // Joined a live window while still shown (`tab_add` activated it and returned the browser):
            // present's page-shown and geometry steps, which it skipped for a tab with no browser.
            // A window still being built shows its shown tab in `windowCreated`.
            if ensureCreated(tab), visibleTab === tab, !tab.awaitsWindowMove { showBrowser(of: tab, activate: false) }
        }
    }

    /// Starts `tab`'s browser: a new Chromium window, or a tab of this host's live or coming one.
    /// True when it joined the live window as Chromium's active tab (`tab_add` with activate).
    @discardableResult
    func ensureCreated(_ tab: CEFTab) -> Bool {
        guard tab.browserID == nil, tab.isCreationPending == false, runtime.acceptsNewBrowsers, let shim = runtime.shim else { return false }
        switch window {
        case .none:
            let request = runtime.makeRequestToken()
            let size = Self.creationSize(for: hostView.bounds.size)
            // A host no pane has laid out (a background tab an agent drives, a
            // pane under a page) takes the size its window starts at, so a
            // later layout pass does not shrink it back to nothing.
            if hostView.window == nil, hostView.bounds.size != size { hostView.setFrameSize(size) }
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
                return false
            }
            // A browser profile's own proxy (#24432), also before the first
            // request: a page the shim cannot proxy never opens (fail closed).
            if tab.machineStore == nil, !key.offTheRecord, key.machineKey == nil, !runtime.applyProfileProxy(key.profile) {
                tab.creationFailed()
                return false
            }
            tab.isCreationPending = true
            windowTab = tab
            window = .creating(request: request)
            runtime.pendingWindows[request] = self
            // The first frame takes this pane's theme scope (room,
            // workspace), which may differ from the app theme.
            shim.setBackgroundColor(PageBackground.themeARGB(in: hostView))
            #if DEBUG || CMUX_BENCH_HOOKS
            ChatOpenTrace.shared.mark(.cefWindowCreate, chromiumPane: key.pane.rawValue)
            #endif
            let initialURL = tab.takeInitialURLString()
            let create = {
                CEFStartSteps.shared.createWindow {
                    shim.createWindow(request, Unmanaged.passUnretained(self.hostView).toOpaque(),
                                      max(size.width, 1).clampedInt32, max(size.height, 1).clampedInt32, initialURL, contextKey)
                }
            }
            #if DEBUG || CMUX_BENCH_HOOKS
            let started = runtime.benchMarks.span("cef.create_window", create)
            #else
            let started = create()
            #endif
            if started != 1 {
                runtime.pendingWindows[request] = nil
                window = .none
                tab.creationFailed()
            }
            return false
        case .creating:
            // Joins the window once it exists (windowCreated).
            tab.isCreationPending = true
            return false
        case .live:
            return addToWindow(tab)
        }
    }

    /// Adds `tab` to the live window; the shown tab becomes Chromium's active tab in the same call
    /// (the one activation of it). True when it joined as the active tab.
    @discardableResult
    private func addToWindow(_ tab: CEFTab) -> Bool {
        guard let shim = runtime.shim, let anchor = tabs.lazy.compactMap(\.browserID).first else {
            window = .none
            return false
        }
        tab.isCreationPending = true
        runtime.tabBeingAdded = tab
        let activates = visibleTab === tab
        let add = { shim.tabAdd(anchor, tab.takeInitialURLString(), -1, activates ? 1 : 0) }
        #if DEBUG || CMUX_BENCH_HOOKS
        let browser = runtime.benchMarks.span("cef.tab_add", add)
        #else
        let browser = add()
        #endif
        runtime.tabBeingAdded = nil
        if browser == 0 {
            tab.creationFailed()
        } else if tab.browserID == nil {
            runtime.register(tab, browser: browser)
        }
        // Chromium's echo of this activation is this host's own (`isForeignActivation`).
        if browser != 0, activates { lastActivated = browser }
        closeSparePlaceholder(joined: tab)
        return browser != 0 && activates
    }

    func windowCreated(browser: Int32, request: Int32) {
        CEFStartSteps.shared.firstWindowEnded()
        guard case .creating(let expected) = window, expected == request, let tab = windowTab else {
            return lateWindowCreated(browser: browser, request: request)
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        ChatOpenTrace.shared.mark(.cefWindowCreated, chromiumPane: key.pane.rawValue)
        runtime.benchMarks.point("cef.window_created")
        #endif
        let windowID = runtime.shim?.tabWindowID(browser) ?? 0
        window = .live(window: windowID)
        lastActivated = browser
        runtime.register(tab, browser: browser)
        hostView.layerHosting.pageWindowCreated(browser: browser, fork: CEFLayerHosting.Fork(shim: runtime.shim, apiVersion: runtime.forkAPIVersion))
        // Tabs shown or created while the window was being built. The window's first tab is its
        // active one until a shown tab joins it as active (`tab_add` with activate).
        var active = tab
        for waiting in tabs where waiting !== tab && waiting.browserID == nil && waiting.isCreationPending {
            waiting.isCreationPending = false
            if addToWindow(waiting) { active = waiting }
        }
        if let visible = visibleTab, !visible.awaitsWindowMove, visible !== active, let id = visible.browserID {
            lastActivated = id
            _ = runtime.shim?.tabActivate(id)
        }
        // The shown tab's page-shown and geometry steps, out of Chromium's creation stack (this
        // runs inside OnAfterCreated): a tab queued while the window was being built, or the
        // window's own tab whose pane moved since the window took its first frame (a pane
        // growing in on its split spring), would keep the place and clip the fork read then.
        endOfTurn { [weak self] in self?.showCreatedWindow() }
        refreshExtensionActions()
        runtime.extensionStores.store(for: key.profile).refresh()
        runtime.orphans.windowBecameLive(self)
        CEFSpareWindow.shared.windowCameUp(self)
        if tabs.contains(where: \.awaitsWindowMove) {
            // Never inside OnAfterCreated (Chromium's tab insertion): moving
            // a tab between tab strips there would re-enter it.
            Task { @MainActor [weak self] in self?.movePopupsIn() }
        }
    }

    /// Chromium made the browser of a window request whose tab closed while the window was built
    /// (or of a request this host no longer waits for): no tab shows it, so it closes, never to show
    /// or leak. Tabs queued for that window would wait for it forever, the pane blank: they ask for
    /// a window again, the shown one first, so it is the new window's own tab: at the end of the
    /// turn, never inside Chromium's creation stack (this runs inside OnAfterCreated).
    private func lateWindowCreated(browser: Int32, request: Int32) {
        runtime.shim?.close(browser)
        guard case .creating(let expected) = window, expected == request else { return }
        window = .none
        let waiting = tabs.filter { $0.browserID == nil && $0.isCreationPending }
        for tab in waiting { tab.isCreationPending = false }
        endOfTurn { [weak self] in self?.recreateWindow(for: waiting) }
    }

    private func recreateWindow(for waiting: [CEFTab]) {
        let open = waiting.filter { tab in !tab.isClosed && tabs.contains(where: { $0 === tab }) }
        // The first creates the window; the rest join it when it comes up (`windowCreated`). A
        // window that came up since (a tab shown meanwhile) takes them now, as `createDeferred` does.
        for tab in open.filter({ $0 === visibleTab }) + open.filter({ $0 !== visibleTab }) {
            if ensureCreated(tab), visibleTab === tab, !tab.awaitsWindowMove { showBrowser(of: tab, activate: false) }
        }
        // A popup still in its opener's window waited for this window too (`ensureOwnWindow`).
        if case .none = window, let popup = tabs.first(where: \.awaitsWindowMove) { ensureOwnWindow(for: popup) }
    }

    /// A tab Chromium opened in this window (target=_blank, window.open,
    /// chrome.tabs.create, a window request the fork placed here). It is
    /// handed to the host app through the opener's delegate as `.adoptTab`,
    /// which keeps `window.opener`.
    /// A `.popup` becomes a floating panel page with its own window
    /// (`adoptPopup`); `bounds` are its window features.
    func adoptChromiumTab(browser: Int32, disposition: BrowserNewTabDisposition = .foregroundTab, bounds: CGRect? = nil) {
        // The spare window has no pane to announce it to: the tab that takes it adopts it.
        if isSpare { return CEFSpareWindow.shared.park(browser, disposition: disposition, bounds: bounds) }
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
        // Opened by a page: past a new tab's first paint (PageBackground), and
        // Chromium, not us, drives its document, so its page area is its own.
        tab.reachedFirstRealPage(settled: true)
        tab.inheritDelegates(from: opener)
        opener?.emit(.adoptTab(tab, disposition))
    }

    func removed(_ tab: CEFTab) {
        tabs.removeAll { $0 === tab }
        if windowTab === tab { windowTab = nil }
        if visibleTab === tab { visibleTab = nil }
        if placeholder === tab { placeholder = nil }
        // The resize deadline addresses the page window through a live browser of it.
        hostView.layerHosting.windowBrowsersChanged(tabs.filter { !$0.awaitsWindowMove }.compactMap(\.browserID))
        // A taken spare whose tab closed before it joined: the spare again.
        if !isPopupHost, tabs.count == 1, placeholder != nil { CEFSpareWindow.shared.giveBack(self, runtime: runtime) }
        if tabs.isEmpty {
            window = .none
            hostView.layerHosting.stop()
            hostView.removeFromSuperview()
            if isPopupHost { runtime.hosts[key] = nil }
        }
    }

    func refreshExtensionActions() {
        for tab in tabs { tab.refreshExtensionActions() }
    }
}

/// A tab a host creates after the frame commits; weak, so a tab closed meanwhile goes.
struct WeakCEFTab {
    weak var tab: CEFTab?
    init(_ tab: CEFTab) { self.tab = tab }
}
