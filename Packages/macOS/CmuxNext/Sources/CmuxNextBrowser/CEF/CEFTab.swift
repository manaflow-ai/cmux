public import AppKit
public import Foundation
public import Observation

/// A Chromium tab (CEF fork, Chrome style). Its page is a child window that
/// tracks `contentView` (`.childWindow` presentation). The Chromium browser
/// is created the first time the tab is shown, so hidden background tabs
/// cost nothing until selected.
@Observable
public final class CEFTab: BrowserTab, BrowserOcclusionHosting, BrowserExtensionActionHosting, BrowserDevToolsHosting, BrowserHangAnswering {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind = .cef
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .childWindow

    public var state: BrowserTabState { machine.state }
    public internal(set) var favicon: NSImage?
    public let pendingPrompts: [BrowserPrompt] = []
    public internal(set) var extensionActions: [CEFExtensionAction] = []
    public internal(set) var openExtensionPopup: String?
    @ObservationIgnored public var extensionActionAnchor: ((String) -> CGRect?)?

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// Permission use of the current document (Page Info).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()

    /// Chromium browser identifier once created.
    @ObservationIgnored public private(set) var browserID: Int32?
    /// Set once by `markAgentDriven`; saved passwords do not fill in this tab.
    @ObservationIgnored public internal(set) var isAgentDriven = false

    /// Rects in `contentView` coordinates where native UI covers the page.
    public var occlusionRects: [CGRect] = [] {
        didSet { applyOcclusion() }
    }

    /// DevTools of this page (docked in `contentView` or in a window).
    public internal(set) var devTools: BrowserDevToolsState
    /// DevTools placement (layout, docked views, window); writes `devTools`.
    @ObservationIgnored let devToolsController: CEFDevToolsController
    /// cmux's header over Chromium's side panel, while it is open.
    @ObservationIgnored var sidePanelHeader: SidePanelHeaderView?
    @ObservationIgnored var sidePanelState: CEFSidePanelState?
    @ObservationIgnored var sidePanelRefreshPending = false
    /// A toolbar click that came before the browser existed.
    @ObservationIgnored var pendingExtensionAction: (id: String, anchor: CGRect)?
    @ObservationIgnored public weak var devToolsObserver: (any BrowserDevToolsObserving)?

    var machine = BrowserTabStateMachine()
    @ObservationIgnored var isCreationPending = false
    @ObservationIgnored var navigation: BrowserNavigationID?
    @ObservationIgnored var nextNavigation: UInt64 = 0
    @ObservationIgnored var pendingURL: URL?
    @ObservationIgnored var pendingFocus = false
    /// True while cmux's own `SetFocus(true)` runs (`chromiumRequestsFocus`).
    @ObservationIgnored var isGrantingFocus = false
    /// Navigation state to restore once the browser exists (created with
    /// an empty URL so its history starts empty).
    @ObservationIgnored var pendingRestore: String?
    /// The renderer ended while the tab was hidden: reload when shown
    /// (Chrome reloads a crashed background tab when it is selected).
    @ObservationIgnored var reloadWhenShown = false
    /// The tab showed a real page (or a page opened it): its page
    /// background is Chrome's white from now on (`PageBackground`).
    @ObservationIgnored private(set) var pastFirstRealPage = false
    /// URL of the last main-frame load that committed (Chromium's current
    /// entry). Renderer debug URLs (chrome://crash) never commit.
    @ObservationIgnored var committedURL: URL?
    @ObservationIgnored var findContinuation: CheckedContinuation<BrowserFindResult, Never>?
    @ObservationIgnored var nextFindID: Int32 = 1
    @ObservationIgnored var faviconTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var isOccluded = false
    /// The pane window this tab belongs to. A popup starts in its opener's
    /// Chromium window but belongs to its own popup host from adoption on;
    /// `awaitsWindowMove` is true until Chromium moved it there.
    @ObservationIgnored var host: CEFPaneHost
    @ObservationIgnored var awaitsWindowMove = false
    /// The host of the page that opened this popup: it shows its own page
    /// again once the popup left its window.
    @ObservationIgnored weak var popupOpenerHost: CEFPaneHost?
    @ObservationIgnored unowned let runtime: CEFRuntime
    @ObservationIgnored lazy var container: CEFTabContentView = {
        let view = CEFTabContentView()
        view.tab = self
        return view
    }()

    /// The remote-localhost derived store, nil for the profile's own store.
    @ObservationIgnored var machineStore: BrowserMachineStore?
    @ObservationIgnored var navigationGuard: BrowserNavigationGuard = .none

    init(id: BrowserTabID, profile: BrowserProfileID, host: CEFPaneHost, runtime: CEFRuntime) {
        self.id = id
        self.profileID = profile
        self.host = host
        self.runtime = runtime
        let layout = CEFDevToolsLayout.remembered
        devToolsController = CEFDevToolsController(layout: layout)
        devTools = BrowserDevToolsState(dock: layout.dock)
        devToolsController.tab = self
    }

    public var contentView: NSView { container }

    var initialURLString: String {
        // An empty URL creates the browser without navigating, which
        // `cmux_tab_restore_navigation` needs.
        pendingRestore != nil ? "" : pendingURL?.absoluteString ?? "about:blank"
    }

    // MARK: Lifetime (called by CEFPaneHost / CEFRuntime)

    func attach(browser: Int32) {
        browserID = browser
        isCreationPending = false
        applyPageBackground()
        applyPasswordFill()
        let zoom = machine.state.zoom
        if zoom != 1 { runtime.shim?.setZoomLevel(browser, CEFZoom.level(forFactor: zoom)) }
        // Focus asked for while the page was being created applies only if
        // the page is still shown: CEF's SetFocus activates (orders front)
        // the page window, which for a page that is no longer selected put
        // it back on screen over the pane's current tab.
        let shown = host.visibleTab === self && !isOccluded
        host.lifecycleTrace.record(id, "attach pendingFocus=\(pendingFocus) shown=\(shown)")
        if pendingFocus, shown { grantFocus(browser) }
        if let action = pendingExtensionAction {
            pendingExtensionAction = nil
            runExtensionAction(action.id, anchor: action.anchor)
        }
        if let state = pendingRestore {
            pendingRestore = nil
            // 1 = restored; fork API 10 reports why not (-1 committed entries,
            // -2 navigation not dropped, -3 state does not decode).
            let code = state.withCString { runtime.shim?.tabRestoreNavigation(browser, $0) } ?? 0
            host.lifecycleTrace.record(id, "restore-navigation \(code == 1 ? "ok" : "failed(\(code))")")
            if code != 1, let url = pendingURL { runtime.shim?.loadURL(browser, url.absoluteString) }
        }
        if let state = pendingRestore {
            pendingRestore = nil
            let restored = state.withCString { runtime.shim?.tabRestoreNavigation(browser, $0) } == 1
            host.lifecycleTrace.record(id, "restore-navigation \(restored ? "ok" : "failed")")
            if !restored, let url = pendingURL { runtime.shim?.loadURL(browser, url.absoluteString) }
        }
        if navigationGuard != .none { runtime.shim?.setNavigationGuard(browser, navigationGuard.rawValue) }
        refreshExtensionActions()
    }

    /// A real page committed, or a page opened this tab (a popup,
    /// target=_blank): Chrome's white default from now on, kept across tab
    /// moves and popups (fork API 12).
    func reachedFirstRealPage() {
        guard !pastFirstRealPage else { return }
        pastFirstRealPage = true
        applyPageBackground()
    }

    /// The tab's view moved or its theme scope changed: a page still on
    /// the theme color takes the new scope's color.
    func pageThemeDidChange() {
        guard !pastFirstRealPage else { return }
        applyPageBackground()
    }

    /// Every attached tab owns its background (theme color of its own
    /// scope until the first real page, then white), so a theme change of
    /// another room or workspace never repaints it.
    private func applyPageBackground() {
        guard let browser = browserID, let shim = runtime.shim else { return }
        _ = shim.browserSetBackgroundColor(browser, PageBackground.chromiumARGB(pastFirstRealPage: pastFirstRealPage,
                                                                                 theme: PageBackground.themeARGB(in: container)))
    }

    func creationFailed() {
        isCreationPending = false
        let error = BrowserLoadError(domain: "CEF", code: -1, message: Strings.cefUnavailable, failingURL: pendingURL)
        let id = makeNavigationID()
        machine.apply(.started(id, url: pendingURL))
        machine.apply(.failed(id, error))
    }

    func browserDidClose() {
        browserID = nil
        findContinuation?.resume(returning: .none)
        findContinuation = nil
        host.removed(self)
        if !isClosed {
            isClosed = true
            emit(.close)
        }
    }

    func contentDidAppear(in view: CEFTabContentView) {
        guard !isClosed else { return }
        host.present(self, in: view)
        view.layoutContent()
        if reloadWhenShown {
            reloadWhenShown = false
            if state.processExit != nil { reload() }
        }
    }

    /// The renderer ended (crash, kill, out of memory, launch failure). The
    /// pane shows the sad tab; a hidden tab reloads when it is shown.
    func rendererTerminated(_ exit: BrowserProcessExit) {
        guard !isClosed else { return }
        machine.apply(.processExited(exit))
        reloadWhenShown = host.visibleTab !== self
        findContinuation?.resume(returning: .none)
        findContinuation = nil
        runtime.recordRendererExit(exit, tab: self)
    }

    func contentDidDisappear() {
        host.conceal(self)
    }

    func emit(_ intent: BrowserTabIntent) {
        delegate?.browserTab(self, didRequest: intent)
    }

    func inheritDelegates(from opener: CEFTab?) {
        delegate = opener?.delegate
        keyRouter = opener?.keyRouter
        devToolsObserver = opener?.devToolsObserver
    }

    func makeNavigationID() -> BrowserNavigationID {
        nextNavigation += 1
        return BrowserNavigationID(rawValue: nextNavigation)
    }

    // MARK: BrowserTab

    public func load(_ url: URL) {
        guard !isClosed else { return }
        let id = makeNavigationID()
        navigation = id
        machine.apply(.started(id, url: url))
        if let browserID {
            runtime.shim?.loadURL(browserID, url.absoluteString)
        } else {
            pendingURL = url
        }
    }

    public func goBack() { browserID.map { runtime.shim?.goBack($0) } }
    public func goForward() { browserID.map { runtime.shim?.goForward($0) } }

    public func reload() {
        reloadWhenShown = false
        guard let browserID else {
            if let url = pendingURL ?? state.url { load(url) }
            return
        }
        switch reloadPlan {
        case .reloadEntry:
            runtime.shim?.reload(browserID)
        case .load(let url):
            // The sad tab clears now, not when the new renderer's first
            // callback arrives.
            let id = makeNavigationID()
            navigation = id
            machine.apply(.started(id, url: url))
            runtime.shim?.loadURL(browserID, url.absoluteString)
        }
    }

    /// How Reload recovers the page.
    enum ReloadPlan: Equatable {
        /// Chromium reloads its current (last committed) entry.
        case reloadEntry
        /// Load this URL (the page died before any load committed).
        case load(URL)
    }

    var reloadPlan: ReloadPlan {
        // With a committed entry Chromium reloads it (history kept); only a
        // page that died before its first commit is loaded by URL.
        guard state.processExit != nil, committedURL == nil, let url = state.url else { return .reloadEntry }
        return .load(url)
    }

    /// Answers "Page unresponsive": wait restarts Chromium's hang timer,
    /// terminate ends the renderer (the sad tab follows).
    public func answerUnresponsivePage(terminate: Bool) {
        guard state.isUnresponsive else { return }
        if let browserID { _ = runtime.shim?.unresponsiveReply(browserID, terminate ? 1 : 0) }
        if !terminate { machine.apply(.unresponsiveChanged(false)) }
    }

    public func stop() {
        browserID.map { runtime.shim?.stop($0) }
        machine.apply(.stopped)
    }

    public func setFocused(_ focused: Bool) {
        let shown = host.visibleTab === self && !isOccluded
        host.lifecycleTrace.record(id, "focus(\(focused)) created=\(browserID != nil) shown=\(shown)")
        pendingFocus = focused
        // Never activate a hidden page's window (see `attach`).
        guard !focused || shown, let browserID else { return }
        if focused { grantFocus(browserID) } else { runtime.shim?.setFocus(browserID, 0) }
    }

    /// Hides the page window (and a docked DevTools) at once, or shows it.
    /// Nothing here awaits: the page is hidden before this returns, so a
    /// later show can never be undone by a completion of this hide (the
    /// old implementation hid the page after awaiting a screenshot, and
    /// that late hide could land on a page shown again meanwhile).
    public func setContentVisible(_ visible: Bool) {
        host.lifecycleTrace.record(id, "visible(\(visible)) was=\(!isOccluded) shown=\(host.visibleTab === self)")
        guard visible == isOccluded else { return }
        isOccluded = !visible
        if host.visibleTab === self { host.hostView.isHidden = !visible }
        devToolsController.views?.host.isHidden = !visible
    }

    /// Whether the content lifecycle hid this page (read by the pane host
    /// when the tab's content view enters a window).
    var isContentHidden: Bool { isOccluded }

    public func snapshot() async throws -> CGImage {
        guard let browserID, !isClosed else { throw BrowserTabError.snapshotUnavailable }
        let json = try await runtime.devTools(browserID, method: "Page.captureScreenshot", params: ["format": "png"])
        return try CEFDevToolsResult.screenshot(json)
    }

    public func setZoom(_ zoom: Double) {
        machine.apply(.zoomChanged(zoom))
        browserID.map { runtime.shim?.setZoomLevel($0, CEFZoom.level(forFactor: zoom)) }
    }

    public func exitContentFullscreen() {
        guard state.isContentFullscreen else { return }
        Task { _ = try? await evaluate("document.exitFullscreen && document.exitFullscreen()") }
    }

    public func showDevTools() { performDevTools(.show) }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        faviconTask?.cancel()
        if let browserID {
            runtime.shim?.close(browserID)
        } else {
            host.removed(self)
        }
        container.removeFromSuperview()
    }
}
