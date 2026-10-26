public import AppKit
public import CmuxNextDesign
public import Foundation
public import Observation
import CmuxNextWakeups

/// A Chromium tab (CEF fork, Chrome style). Its page is a child window that
/// tracks `contentView` (`.childWindow` presentation). The Chromium browser
/// is created the first time the tab is shown, so hidden background tabs
/// cost nothing until selected.
@Observable
public final class CEFTab: BrowserTab, BrowserOcclusionHosting, BrowserExtensionActionHosting, BrowserDevToolsHosting, BrowserHangAnswering,
    BrowserAgentFileChoosing {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind = .cef
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .childWindow

    public var state: BrowserTabState { machine.state }
    public internal(set) var favicon: NSImage?
    public internal(set) var pendingPrompts: [BrowserPrompt] = []
    public internal(set) var extensionActions: [CEFExtensionAction] = []
    public internal(set) var openExtensionPopup: String?
    @ObservationIgnored public var extensionActionAnchor: ((String) -> CGRect?)?

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// Permission use of the current document (Page Info).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()
    /// Chrome's automatic-downloads rule for this page (CEFTab+Prompts).
    @ObservationIgnored public internal(set) lazy var automaticDownloads = makeAutomaticDownloadGate()

    /// Chromium browser identifier once created.
    @ObservationIgnored public private(set) var browserID: Int32?
    /// Set once by `markAgentDriven`; saved passwords do not fill in this tab.
    @ObservationIgnored public internal(set) var isAgentDriven = false
    @ObservationIgnored var passwordFill = PasswordFillState()
    /// The browser host's raw DevTools relay of this page.
    @ObservationIgnored public private(set) lazy var agentRelay = CEFAgentRelay(tab: self)
    /// Files an agent offered this page's next file chooser; Chromium sends choosers to the app while one
    /// stands (`CEFRuntime+FileDialogs`).
    @ObservationIgnored public private(set) lazy var agentFiles: BrowserAgentFiles = {
        let files = BrowserAgentFiles()
        files.onArmedChange = { [weak self] armed in
            guard let self else { return }
            runtime.agentFileOfferChanged(self, armed: armed)
        }
        return files
    }()

    /// Rects in `contentView` coordinates where native UI covers the page.
    public var occlusionRects: [CGRect] = [] {
        didSet { applyOcclusion() }
    }

    /// DevTools of this page (docked in `contentView` or in a window).
    public internal(set) var devTools: BrowserDevToolsState
    /// DevTools placement (layout, docked views, window); writes `devTools`.
    @ObservationIgnored let devToolsController: CEFDevToolsController
    /// cmux's header over Chromium's side panel (`CEFSidePanelController`).
    @ObservationIgnored private(set) lazy var sidePanel = CEFSidePanelController(tab: self)
    /// A toolbar click that came before the browser existed.
    @ObservationIgnored var pendingExtensionAction: (id: String, anchor: CGRect)?
    @ObservationIgnored public weak var devToolsObserver: (any BrowserDevToolsObserving)?
    /// The page's Developer Tools modes (cache off, throttling, overlays,
    /// emulated media) that cmux's DevTools session set (`WebDevToolsToggles`).
    @ObservationIgnored public var devToolsModes = WebDevToolsToggles()
    /// The color scheme the tab was asked for (`BrowserPageModes.colorScheme`).
    /// `.system` resolves to the view's appearance on every send, so a theme
    /// change reaches the page (`CEFTab+ColorScheme`).
    @ObservationIgnored var colorScheme: BrowserColorScheme = .system

    var machine = BrowserTabStateMachine()
    /// Title changes reach `machine` at most 4 a second (`TitleCoalescer`, idle power).
    @ObservationIgnored var titleCoalescer = TitleCoalescer()
    @ObservationIgnored let titleTimer = DemandTimer(owner: "CEFTab.title")
    @ObservationIgnored var isCreationPending = false
    @ObservationIgnored var navigation: BrowserNavigationID?
    @ObservationIgnored var nextNavigation: UInt64 = 0
    @ObservationIgnored var pendingURL: URL?
    /// The page `attach` loads: an agent-driven tab was created blank
    /// (`takeInitialURLString`).
    @ObservationIgnored var loadAfterAttach: URL?
    @ObservationIgnored var pendingFocus = false
    /// True while cmux's own `SetFocus(true)` runs (`chromiumRequestsFocus`).
    @ObservationIgnored var isGrantingFocus = false
    /// Navigation state to restore once the browser exists (created with
    /// an empty URL so its history starts empty).
    @ObservationIgnored var pendingRestore: String?
    /// The renderer ended while the tab was hidden: reload when shown
    /// (a crashed background tab reloads when it is selected).
    @ObservationIgnored var reloadWhenShown = false
    /// The tab showed a real page (or a page opened it): its page
    /// background is Chromium's white from now on (`PageBackground`).
    /// Settable inside the module, not only this file: `reachedFirstRealPage`
    /// is in `CEFTab+LoadingBackground` with the rest of the page background.
    @ObservationIgnored var pastFirstRealPage = false
    /// The document's own background, 0xAARRGGBB, once read (nil: Chromium's
    /// white); counts for resize gaps (`CEFTab+ResizeBackdrop`).
    @ObservationIgnored var pageBackdropARGB: UInt32?
    /// Bumped on each committed document, so a read of the previous one is dropped.
    @ObservationIgnored var pageBackdropDocument = 0
    /// The committed document's load settled, so the page area is its own.
    /// Until then the page base is the theme color, not the engine's white
    /// (`CEFTab+LoadingBackground`).
    @ObservationIgnored var documentSettled = false
    /// The `prefers-color-scheme` a live renderer was last told, so a tab
    /// switch (every one calls `pageThemeDidChange`) costs no DevTools round
    /// trip when nothing changed. Nil whenever no page can be holding that
    /// value: before the browser attaches, once it goes away, and from a
    /// renderer's death until the restart commits a document
    /// (`CEFTab+ColorScheme`, `rendererTerminated`).
    @ObservationIgnored var sentColorScheme: String?
    /// The theme surface whose color a cmux page keeps behind its transparent document (a
    /// `cmux-page://` page in Chromium, `CmuxNextApp` `ChromiumPageHost`); nil for a web page, which
    /// turns white at its first real page like Chrome.
    @ObservationIgnored public var pageThemeSurface: SurfaceKind? {
        didSet { if pageThemeSurface != oldValue { applyPageBackground() } }
    }
    /// The page is see-through (fork API 17): where its document draws no background, the pane and
    /// the window backdrop show, as under a WebKit page that draws none. A cmux page sets it (the page
    /// host, `PageChromiumPage.setSeeThrough`); a web page stays opaque like Chrome.
    @ObservationIgnored public var pageSeeThrough = false {
        didSet {
            guard pageSeeThrough != oldValue else { return }
            // A web page never calls the fork's see-through switch; only a page leaving see-through does.
            if !pageSeeThrough, let browserID { _ = runtime.shim?.tabSetTransparentBackground(browserID, 0) }
            applyPageBackground()
        }
    }
    /// Answers the page's requests for its dynamic paths (a cmux page whose scheme entry has
    /// ``CEFPageSchemes/Entry/dynamicPrefixes``); nil answers every one with a 404.
    @ObservationIgnored public var pageResources: (@MainActor (URL) async -> CEFPageResponse)?
    /// A drag of these files from outside the app entered the page (a cmux page hands such a drop
    /// to its host); nil ignores it.
    @ObservationIgnored public var pageFilesDragged: (@MainActor ([URL]) -> Void)?
    /// A real mouse down or key down reached the page, at this `systemUptime` (a cmux page backs its
    /// calls with it as the person's gesture); nil ignores it.
    @ObservationIgnored public var pageUserInput: (@MainActor (TimeInterval) -> Void)?

    /// The file URLs of a PAGE_DRAG_ENTER event's JSON array of absolute paths.
    nonisolated static func dragPaths(_ json: String) -> [URL] {
        guard let paths = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String] else { return [] }
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }
    /// URL of the last main-frame load that committed (Chromium's current
    /// entry). Renderer debug URLs (chrome://crash) never commit.
    @ObservationIgnored var committedURL: URL?
    /// Chromium's own Back/Forward state; the tab also offers the entries
    /// saved before a relaunch (`restored`).
    @ObservationIgnored var nativeHistory = (back: false, forward: false)
    @ObservationIgnored lazy var restored = CEFRestoredSession(tab: self)
    /// A title Chromium reported before its own navigation (Back, Forward,
    /// a page-initiated load) committed. Back and Forward report the entry's
    /// title first, and a page restored from the back/forward cache never
    /// sets it again, so commit keeps it. Only navigations Chromium started
    /// capture one (`capturesTitleBeforeCommit`); every new navigation id
    /// and every navigation that ends without committing clears it.
    @ObservationIgnored var titleBeforeCommit: String?
    @ObservationIgnored var capturesTitleBeforeCommit = false
    /// The pending find-in-page request (`CEFFindRequests`).
    @ObservationIgnored var findRequests = CEFFindRequests()
    /// The daemon's resolved emulation (`CEFTab+DeviceEmulation`), its last layout size and scale,
    /// whether an override is on the page, and the calls in flight.
    @ObservationIgnored public internal(set) var deviceEmulation: BrowserEmulation?
    @ObservationIgnored var deviceEmulationViewport: BrowserEmulation.Viewport?
    /// View points per CSS px the emulation applies now (the viewport's scale; 1 for none). Observed:
    /// the app announces it to the browser host, which scales an agent's mouse input by it (cx-mogig).
    public internal(set) var emulationInputScale: Double = 1
    /// The emulation turned touch on (a phone or tablet preset). Observed: the app announces it, and the
    /// browser host sends an agent's pointer input as touch, which Chromium answers (cx-3ny35).
    public internal(set) var emulationTouch = false
    @ObservationIgnored var deviceEmulationApplied = false
    @ObservationIgnored var deviceEmulationTask: Task<Void, Never>?
    @ObservationIgnored var deviceEmulationDirty = false
    /// The next emulation run clears this session's metrics first (after DevTools device mode).
    @ObservationIgnored var deviceEmulationNeedsReset = false
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
    @ObservationIgnored public internal(set) var machineStore: BrowserMachineStore?
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

    /// The URL the browser is created with. An empty URL creates it without
    /// navigating, which `cmux_tab_restore_navigation` needs, and which an
    /// agent-driven tab uses too: its page loads in `attach`, once the shim
    /// knows the tab is agent-driven (`CEFAgentURLGuard.defersCreationLoad`),
    /// as its first navigation (no blank entry before it).
    func takeInitialURLString() -> String {
        loadAfterAttach = nil
        guard pendingRestore == nil else { return "" }
        if CEFAgentURLGuard.defersCreationLoad(pendingURL, agentDriven: isAgentDriven) {
            loadAfterAttach = pendingURL
            return ""
        }
        return CEFAgentURLGuard.creationURL(pendingURL, agentDriven: isAgentDriven)
    }

    // MARK: Lifetime (called by CEFPaneHost / CEFRuntime)

    func attach(browser: Int32) {
        browserID = browser
        isCreationPending = false
        CEFAgentURLGuard.applyShimGuard(self)
        if let url = loadAfterAttach {
            loadAfterAttach = nil
            runtime.shim?.loadURL(browser, url.absoluteString)
        }
        applyPageBackground()
        // A page following the app needs the theme's appearance before it
        // paints: Chromium's own window never inherits the view's. This
        // browser has heard nothing yet, whatever an earlier one was told.
        sentColorScheme = nil
        reapplyColorScheme()
        applyPasswordFill()
        leaveAutomaticDownloadsToCmux(browser)
        applyDeviceEmulation()
        agentRelay.browserAttached()
        if host.freezesPlaceholder, host.placeholder === self { freezeNeverShownPage(browser) }
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
        refreshExtensionActions()
    }

    // What the page area shows, and when the document takes it over, are in
    // `CEFTab+LoadingBackground`.

    func creationFailed() {
        isCreationPending = false
        agentRelay.resumeWaiters(false)
        let error = BrowserLoadError(domain: "CEF", code: -1, message: Strings.cefUnavailable, failingURL: pendingURL)
        let id = makeNavigationID()
        machine.apply(.started(id, url: pendingURL))
        machine.apply(.failed(id, error))
    }

    /// Chromium destroyed the browser. `closesTab` is false when quit
    /// closed it (`CEFRuntime.shutdown`): the engine ends, the tab stays in
    /// the daemon and reopens at relaunch.
    func browserDidClose(closesTab: Bool = true) {
        browserID = nil
        agentRelay.browserEnded()
        findRequests.cancel()
        dismissPrompts()
        host.removed(self)
        if !isClosed {
            isClosed = true
            if closesTab { emit(.close) }
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
        // A new renderer need not keep the old one's media emulation, so forget
        // what the dead one was told: whichever way the page comes back (Reload
        // here, or a hidden tab reloading when shown), the restarted renderer's
        // `.loadStart` sends the color scheme again rather than trusting a memo
        // no live page ever heard.
        sentColorScheme = nil
        machine.apply(.processExited(exit))
        // After the sad tab, not before it: no first paint or load end is
        // coming for the document that was loading, so the page area stops
        // standing in for it (`CEFTab+LoadingBackground`) -- but settling
        // repaints the base white, and doing that before the view that reads
        // `state.processExit` is laid out shows a white page area for a frame
        // in a dark theme.
        documentDidSettle()
        reloadWhenShown = host.visibleTab !== self
        findRequests.cancel()
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
        clearTitleBeforeCommit()
        nextNavigation += 1
        return BrowserNavigationID(rawValue: nextNavigation)
    }

    // MARK: BrowserTab

    public func load(_ url: URL) {
        guard !isClosed else { return }
        automaticDownloads.userGesture()
        let id = makeNavigationID()
        navigation = id
        machine.apply(.started(id, url: url))
        if let browserID {
            runtime.shim?.loadURL(browserID, url.absoluteString)
        } else {
            pendingURL = url
        }
    }

    public func goBack() {
        if !nativeHistory.back, restored.step(by: -1) { return }
        browserID.map { runtime.shim?.goBack($0) }
    }

    /// Saved forward entries sit right after Chromium's first entry
    /// (`BrowserRestoredHistory`), so they come first from there.
    public func goForward() {
        if !nativeHistory.back, restored.step(by: 1) { return }
        browserID.map { runtime.shim?.goForward($0) }
    }

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
        clearTitleBeforeCommit()
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

    /// Shows the page window (and a docked DevTools) at once, or hides it by
    /// the end of this run-loop turn, before the frame commits. Nothing here
    /// awaits: the hide reads the host's state when it runs, so a later show
    /// can never be undone by it (an older hide that awaited a screenshot
    /// could land on a page shown again meanwhile).
    public func setContentVisible(_ visible: Bool) {
        host.lifecycleTrace.record(id, "visible(\(visible)) was=\(!isOccluded) shown=\(host.visibleTab === self)")
        guard visible == isOccluded else { return }
        isOccluded = !visible
        // Show at once; a hide waits for the end of the turn (CEFPaneHost.setNeedsHostVisibility).
        if host.visibleTab === self { if visible { host.hostView.isHidden = false } else { host.setNeedsHostVisibility() } }
        devToolsController.views?.host.isHidden = !visible
    }

    /// Whether the content lifecycle hid this page (read by the pane host
    /// when the tab's content view enters a window).
    var isContentHidden: Bool { isOccluded }

    public func snapshot() async throws -> CGImage { try await CEFThumbnail.capture(self, CEFThumbnail.png) }
    public func thumbnail() async throws -> CGImage { try await CEFThumbnail.capture(self, CEFThumbnail.params) }

    public func setZoom(_ zoom: Double) {
        machine.apply(.zoomChanged(zoom))
        browserID.map { runtime.shim?.setZoomLevel($0, CEFZoom.level(forFactor: zoom)) }
    }

    public func exitContentFullscreen() {
        guard state.isContentFullscreen else { return }
        Task { [runtime] in _ = try? await evaluate("document.exitFullscreen && document.exitFullscreen()", world: .page, gesture: .cmux); withExtendedLifetime(runtime) {} }
    }

    public func showDevTools() { performDevTools(.show) }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        agentRelay.resumeWaiters(false)
        agentFiles.withdraw()
        titleTimer.cancel()
        faviconTask?.cancel()
        dismissPrompts()
        if let browserID {
            runtime.shim?.close(browserID)
        } else {
            host.removed(self)
        }
        container.removeFromSuperview()
    }
}
