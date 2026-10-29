import AppKit
import CmuxNextCompat
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
        /// Host mode: the first tab waits for the host's verdict on its profile's proxy before the window
        /// is asked for (`awaitProfileProxy`); later tabs join the wait as they join `creating`.
        case awaitingProfileProxy
        /// The profile's first tab waits for its built-in extensions before the window is asked for
        /// (`CEFPaneHost+BuiltInExtensions`); later tabs join the wait as they join `creating`.
        case awaitingExtensions
        case creating(request: Int32)
        case live(window: Int32)
    }

    var window: WindowState = .none { didSet { runtime.windowRequests.policyMayHaveChanged() } }
    /// Tabs of this host, in creation order.
    private(set) var tabs: [CEFTab] = [] { didSet { runtime.windowRequests.policyMayHaveChanged() } }
    /// The tab whose creation created the window.
    var windowTab: CEFTab?
    /// The tab currently shown in `hostView`.
    private(set) weak var visibleTab: CEFTab?
    /// The browser this host last made Chromium's active tab (its own
    /// `cmux_tab_activate`, or the window's first tab). Chromium echoes an
    /// activation for it, often after the user has moved on.
    var lastActivated: Int32?
    /// A popup host's about:blank browser that created its Chromium window;
    /// it closes once the popup moved in (`CEFPaneHost+Popups`).
    var placeholder: CEFTab?
    /// The placeholder is a spare window's (`CEFSpareWindow`): never shown, so Chromium never learns it is
    /// hidden. With `CEFSpareWindow.rendererlessPlaceholders` it is made with no renderer where the fork can,
    /// else its page is frozen once its browser exists.
    var quietsPlaceholder = false
    /// This window's placeholder has no renderer (`cmux_shim_create_placeholder_window`): no page to set up or freeze.
    private(set) var placeholderHasNoRenderer = false
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
        // A popup host's page window hosts or attaches only on a fork that does it for popups (`CEFLayerHosting.Fork`).
        hostView.layerHosting.widget = isPopupHost ? .popup : .page
        hostView.layerHosting.isPageVisible = { [weak self] in self?.visibleTab.map { !$0.isContentHidden } ?? false }
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
        switch window {
        case .creating, .awaitingProfileProxy, .awaitingExtensions: true
        case .none, .live: false
        }
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
    /// Host mode: the view this pane's page shows in, made by the first window the pane asks for
    /// (`pageParent`). It names the page's parent view on the wire and shows the Core Animation
    /// context id the host gives for it (``ChromiumHostPageView/show(contextID:)``).
    var hostedPageView: ChromiumHostPageView?
    /// Host mode: each browser's last page cursor (`CEFPaneHost+Cursor`).
    var pageCursors: [Int32: CEFPageCursor] = [:]
    /// Host mode: tabs whose window waits for the host's answer on their machine store's proxy
    /// (`createAfterMachineProxy`).
    var machineProxyWaits: Set<ObjectIdentifier> = []

    /// The host view's visibility is derived: hidden unless the shown tab is
    /// not concealed. A conceal queues one pass for the end of this run-loop
    /// turn (before the frame commits), so a same-pane switch, which conceals
    /// the old tab and presents the new one in the same turn, never takes the
    /// page window off screen (cx-asb1: Chromium then saw a window hide/show
    /// instead of a tab switch, about 100 ms late under load).
    func setNeedsHostVisibility() {
        guard !hostVisibilityPending else { return }
        hostVisibilityPending = true
        // input-hop-allow: the pass must run in this run-loop pass's blocks, before Core Animation commits its frame; a classed post can land after the commit and show the page window hidden for one frame of a tab switch.
        MainRunLoopBlock.perform { [weak self] in self?.applyHostVisibility() }
    }

    private func applyHostVisibility() {
        hostVisibilityPending = false
        let hidden = visibleTab.map(\.isContentHidden) ?? true
        if hostView.isHidden != hidden { hostView.isHidden = hidden }
        runtime.windowRequests.policyMayHaveChanged()
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
        suggestionsFollowShownBrowser(tab.browserID)
        tab.applyHostBackdrop()
        // Tabs from windows cmux does not host go to a pane, never a panel.
        if !isPopupHost { runtime.lastShownHost = self }
        if attachPopupWindowIfNeeded(tab) { return }
        // A tab shown before its browser exists (a new tab, a hibernated one waking) gets it once
        // this turn's frame is committed: building or joining a Chromium window holds the main
        // thread (`create_window`, `tab_add`), and the tab's toolbar and themed page area must be
        // on screen in the frame of the key that asked for it (PL-cef-tab: < 10 ms). A host that
        // maps cmux's minted ids takes both as posts, so the tab asks for its browser in the key's turn.
        if tab.browserID == nil, !tab.awaitsWindowMove {
            return createsBrowsersAtOnce ? create(tab) : createAfterCommit(tab)
        }
        ensureCreated(tab)
        if tab.awaitsWindowMove {
            // Still in its opener's window: activating it there would show
            // it in the opener's pane. It moves into this host's window. A
            // page tab moved to a pane with no window gets one after the
            // frame commits, as a new tab does (PL-cef-tab).
            if !isPopupHost, !createsBrowsersAtOnce, case .none = window { return createAfterCommit(tab) }
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
        hostedPageView?.exclusiveAccess.showing(nil) // a hidden page's fullscreen and locks end, as Chrome's (task 229)
        visibleTab = nil
        suggestionsFollowShownBrowser(nil)
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

    /// Makes the browsers of the tabs shown before theirs existed, and the window of a moved tab still in another
    /// window (`ensureOwnWindow`): the observer of `createAfterCommit`; tests call it.
    func createDeferred() {
        let waiting = deferredCreations.compactMap(\.tab)
        deferredCreations.removeAll()
        for tab in waiting where !tab.isClosed && tabs.contains(where: { $0 === tab }) {
            if tab.awaitsWindowMove { ensureOwnWindow(for: tab) } else { create(tab) }
        }
    }

    /// Starts `tab`'s browser now. Joined a live window while still shown (`tab_add` activated it
    /// and returned the browser): present's page-shown and geometry steps, which it skipped for a
    /// tab with no browser. A window still being built shows its shown tab in `windowCreated`.
    private func create(_ tab: CEFTab) {
        if ensureCreated(tab), visibleTab === tab, !tab.awaitsWindowMove { showBrowser(of: tab, activate: false) }
    }

    /// Starts `tab`'s browser: a new Chromium window, or a tab of this host's live or coming one.
    /// True when it joined the live window as Chromium's active tab (`tab_add` with activate).
    /// `machineProxyApplied`: the host already said the tab's machine store proxy is stored
    /// (`createAfterMachineProxy`), so a new window does not ask again.
    @discardableResult
    func ensureCreated(_ tab: CEFTab, machineProxyApplied: Bool = false) -> Bool {
        guard tab.browserID == nil, !tab.isCreationPending, !tab.awaitsHostRestore, runtime.acceptsNewBrowsers, let shim = runtime.shim else { return false }
        switch window {
        case .none:
            // A browser profile's own proxy (#24432), before the first request:
            // a page the shim cannot proxy never opens (fail closed).
            if tab.machineStore == nil, !key.offTheRecord, key.machineKey == nil {
                switch runtime.applyProfileProxy(key.profile) {
                case .open: break
                case .refused:
                    tab.creationFailed()
                    return false
                case .waiting:
                    awaitProfileProxy(first: tab)
                    return false
                }
            }
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
            } else if !createsBrowsersAtOnce {
                // CEF refuses a request context whose cache directory is missing. A host that maps
                // cmux's ids makes it itself, off this thread (the shim's RequestContextFor).
                try? FileManager.default.createDirectory(at: URL(filePath: contextKey), withIntermediateDirectories: true)
            }
            // A remote-localhost store: its context must use the proxy before
            // its first request, or localhost would reach this Mac (fail closed).
            if let store = tab.machineStore, !machineProxyApplied {
                switch machineProxyGate(tab, store, contextKey: contextKey) {
                case .open: break
                case .refused:
                    tab.creationFailed()
                    return false
                case .waiting:
                    return false
                }
            }
            // After the proxy gates: the extensions' first requests use the profile's proxy.
            guard builtInExtensionsReady(for: tab) else { return false }
            tab.isCreationPending = true
            windowTab = tab
            window = .creating(request: request)
            runtime.pendingWindows[request] = self
            // The first frame takes this pane's theme scope (room,
            // workspace), which may differ from the app theme.
            shim.setBackgroundColor(PageBackground.themeARGB(in: hostView))
            runtime.chatStage(.cefWindowCreate, pane: key.pane.rawValue)
            #if DEBUG || CMUX_BENCH_HOOKS
            ChatOpenTrace.shared.mark(.cefWindowCreate, chromiumPane: key.pane.rawValue)
            #endif
            let initialURL = tab.takeInitialURLString()
            // Set before AFTER_CREATED can reach the placeholder's attach.
            placeholderHasNoRenderer = quietsPlaceholder && placeholder === tab && runtime.spareWindow.rendererlessPlaceholders
                && shim.placeholderSupported() == 1
            let rendererless = placeholderHasNoRenderer
            let spare = quietsPlaceholder && placeholder === tab
            let hostMode = runtime.hostStart != nil
            let createTrace = runtime.spareWindow.createTrace
            let view = pageParent()
            let create = {
                CEFStartSteps.shared.createWindow {
                    let width = max(size.width, 1).clampedInt32, height = max(size.height, 1).clampedInt32
                    return createTrace.create(request: request, spare: spare, profile: self.key.profile, hostMode: hostMode) {
                        rendererless ? shim.createPlaceholderWindow(request, view, width, height, contextKey)
                            : shim.createWindow(request, view, width, height, initialURL, contextKey)
                    }
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
                placeholderHasNoRenderer = false
                tab.creationFailed()
            } else {
                runtime.spareWindow.noteWindowBuilt(for: key)
            }
            return false
        case .awaitingProfileProxy, .awaitingExtensions, .creating:
            // Joins the window once it exists (windowCreated), or the proxy or extensions wait.
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
        // `tab_add` navigates in the call: the profile's built-in extensions are in first.
        guard builtInExtensionsReady(for: tab) else { return false }
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
        runtime.chatStage(.cefWindowCreated, pane: key.pane.rawValue)
        #if DEBUG || CMUX_BENCH_HOOKS
        ChatOpenTrace.shared.mark(.cefWindowCreated, chromiumPane: key.pane.rawValue)
        runtime.benchMarks.point("cef.window_created")
        #endif
        let windowID = runtime.shim?.tabWindowID(browser) ?? 0
        window = .live(window: windowID)
        lastActivated = browser
        runtime.register(tab, browser: browser)
        hostView.layerHosting.switchCommit.hiddenFrames = runtime.hiddenFrames
        // In host mode the page shows in `hostedPageView`, from the context the host gives; the
        // fork's layer hosting of a page window over `hostView` is in process only.
        hostView.layerHosting.pageWindowCreated(
            browser: browser, fork: isHostMode ? nil : CEFLayerHosting.Fork(runtime: runtime))
        if isHostMode { showHostedContext(of: browser) }
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
        runtime.spareWindow.windowCameUp(self)
        if tabs.contains(where: \.awaitsWindowMove) {
            // Never inside OnAfterCreated (Chromium's tab insertion): moving
            // a tab between tab strips there would re-enter it.
            endOfTurn { [weak self] in self?.movePopupsIn() }
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

    /// Asks for a window for `waiting`, the shown tab first (after a late window or a proxy verdict).
    func recreateWindow(for waiting: [CEFTab]) {
        let open = waiting.filter { tab in !tab.isClosed && tabs.contains(where: { $0 === tab }) }
        // The first creates the window; the rest join it when it comes up (`windowCreated`). A
        // window that came up since (a tab shown meanwhile) takes them now, as `createDeferred` does.
        for tab in open.filter({ $0 === visibleTab }) + open.filter({ $0 !== visibleTab }) {
            if ensureCreated(tab), visibleTab === tab, !tab.awaitsWindowMove { showBrowser(of: tab, activate: false) }
        }
        // A popup still in its opener's window waited for this window too (`ensureOwnWindow`).
        if case .none = window, let popup = tabs.first(where: \.awaitsWindowMove) { ensureOwnWindow(for: popup) }
    }

    func removed(_ tab: CEFTab) {
        // A closed page's fullscreen zoom, locks and hidden cursor end with it (task 229); a moved one exits its own.
        if tab.isClosed || tab.browserID == nil { tab.contentFullscreenEnded() }
        if visibleTab === tab { hostedPageView?.exclusiveAccess.showing(nil) }
        tabs.removeAll { $0 === tab }
        if windowTab === tab { windowTab = nil }
        if visibleTab === tab { visibleTab = nil }
        if placeholder === tab { placeholder = nil }
        suggestionsFollowShownBrowser(visibleTab?.browserID)
        // The resize deadline addresses the page window through a live browser of it.
        hostView.layerHosting.windowBrowsersChanged(tabs.filter { !$0.awaitsWindowMove }.compactMap(\.browserID))
        // A taken spare whose tab closed before it joined: the spare again.
        if !isPopupHost, tabs.count == 1, placeholder != nil { runtime.spareWindow.giveBack(self, runtime: runtime) }
        if tabs.isEmpty {
            window = .none
            hostView.layerHosting.stop()
            hostedPageView?.show(contextID: 0)
            hostView.removeFromSuperview()
            runtime.hostEmptied(self)
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
