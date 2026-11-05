public import AppKit
public import CmuxNextDesign
public import Foundation
public import Observation
import CmuxNextCompat
import CmuxNextWakeups

/// A Chromium tab (CEF fork, Chrome style). Its page is a child window that
/// tracks `contentView` (`.childWindow` presentation). The Chromium browser
/// is created the first time the tab is shown, so hidden background tabs
/// cost nothing until selected.
@Observable
public final class CEFTab: BrowserTab, BrowserOcclusionHosting, BrowserExtensionActionHosting, BrowserDevToolsHosting, BrowserHangAnswering,
    BrowserAgentFileChoosing, BrowserCacheBypassingReload {
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

    /// Rounded native UI in `contentView` coordinates (the prompt and find
    /// bars, `BrowserRoundedOcclusionHosting`): holes with their corners, so the page shows around them.
    var roundedOcclusions: [CEFClipShape.RoundedRect] = [] {
        didSet { if roundedOcclusions != oldValue { applyOcclusion() } }
    }

    /// The hovered link's text (``BrowserTab/linkStatus``), from Chromium's
    /// status message; Chrome's own status bubble is off.
    public internal(set) var linkStatus: String?

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
    /// The one automatic reload a memory end of the renderer owes (``BrowserExitRecovery``).
    @ObservationIgnored var exitRecovery = BrowserExitRecovery()
    /// The system's memory pressure, read when the renderer ends; a test gives a fixed level.
    @ObservationIgnored var memoryPressure: () -> MemoryPressureLevel = { KernelMemoryPressureLevel().read() }
    /// Title changes reach `machine` at most 4 a second (`TitleCoalescer`, idle power).
    @ObservationIgnored var titleCoalescer = TitleCoalescer()
    @ObservationIgnored let titleTimer = DemandTimer(owner: "CEFTab.title")
    /// The bounded wait of a document's background read before it settles (`documentDidPaint`). A test gives it a
    /// manual clock.
    @ObservationIgnored var settleTimer = DemandTimer(owner: "CEFTab.settle")
    @ObservationIgnored var isCreationPending = false
    @ObservationIgnored var navigation: BrowserNavigationID?
    @ObservationIgnored var nextNavigation: UInt64 = 0
    @ObservationIgnored var pendingURL: URL?
    /// The page `attach` loads: an agent-driven tab was created blank
    /// (`takeInitialURLString`).
    @ObservationIgnored var loadAfterAttach: URL?
    /// Focus cmux asked for while the page could not take it (no browser yet, or not shown):
    /// granted once the page shows (``grantPendingFocusIfShown()``).
    @ObservationIgnored var pendingFocus = false
    /// True while cmux's own `SetFocus(true)` runs (`chromiumRequestsFocus`).
    @ObservationIgnored var isGrantingFocus = false
    /// The app's key window (``CEFKeyWindows``): a grant reads it and may move it.
    @ObservationIgnored var keyWindows = CEFKeyWindows.appKit
    /// Navigation state to restore once the browser exists (created with
    /// an empty URL so its history starts empty).
    @ObservationIgnored var pendingRestore: String?
    /// The tab showed a real page (or a page opened it): its page
    /// background is Chromium's white from now on (`PageBackground`).
    /// Settable inside the module, not only this file: `reachedFirstRealPage`
    /// is in `CEFTab+LoadingBackground` with the rest of the page background.
    @ObservationIgnored var pastFirstRealPage = false
    /// The document's own background, 0xAARRGGBB, once read (nil: Chromium's
    /// white); counts for resize gaps (`CEFTab+ResizeBackdrop`).
    @ObservationIgnored var pageBackdropARGB: UInt32?
    /// The document (`pageBackdropDocument`) whose background read is in flight from its paint or load end
    /// (`documentDidPaint`), so the second of the two events starts no second read.
    @ObservationIgnored var pageBackdropReading: Int?
    /// A load end or stop came while that read was in flight: one more read follows its answer.
    @ObservationIgnored var pageBackdropReReadOwed = false
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
    @ObservationIgnored public var pageResources: (@MainActor (URL, String?) async -> CEFPageResponse)?
    /// A drag of these files from outside the app entered the page (a cmux page hands such a drop
    /// to its host); nil ignores it.
    @ObservationIgnored public var pageFilesDragged: (@MainActor ([URL]) -> Void)?
    /// The drag of files the pane relays to the page (``pageFilesDragged``) ended: true in a drop
    /// on the page (AppKit's `performDragOperation`, its event in dispatch), false when it left the
    /// page or was cancelled. Page script cannot make either; nil ignores it.
    @ObservationIgnored public var pageDragEnded: (@MainActor (Bool) -> Void)?
    /// A real mouse down or key down reached the page, at this `systemUptime` (a cmux page backs its
    /// calls with it as the person's gesture); nil ignores it.
    @ObservationIgnored public var pageUserInput: (@MainActor (TimeInterval) -> Void)?
    /// The person pressed Cmd-V in the page, before Chromium pastes (``CEFRuntime/routeKey(_:browser:)``,
    /// the key event in dispatch); nil ignores it.
    @ObservationIgnored public var pagePasted: (@MainActor () -> Void)?
    /// The person picked these files in the app's panel for the page's file chooser. Set, this
    /// page's choosers come to the app (`cmux_shim_browser_set_file_dialogs`); nil leaves them to
    /// Chromium's own panel and its accept filters, as on every other tab.
    @ObservationIgnored public var pageFilesChosen: (@MainActor ([URL]) -> Void)? {
        didSet {
            if (pageFilesChosen == nil) != (oldValue == nil) { runtime.applyFileDialogRoute(self) }
        }
    }

    /// Stops telling the page host about the page's messages, drags, input and pastes (it stopped
    /// listening).
    public func clearPageEventHooks() {
        agentRelay.set(onMessage: nil, onEnd: nil)
        pageFilesDragged = nil
        pageDragEnded = nil
        pageUserInput = nil
        pagePasted = nil
    }

    /// Clears every page-host hook (the page host closed the page): its events, its dynamic paths,
    /// and its file chooser goes back to Chromium.
    public func clearPageHooks() {
        clearPageEventHooks()
        pageResources = nil
        pageFilesChosen = nil
    }

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
    @ObservationIgnored private var isOccluded = false { didSet { if !isOccluded { runtime.extensionActionReads.tabShown(self) } } }
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

    /// The page can take keys from now on: Chromium created its browser and stopped loading with a real document loaded
    /// (or an error page). Before that a key reached the empty document a restore then replaced, a page whose script
    /// had not run, or a document the next navigation of the same load replaced. Once per browser.
    @ObservationIgnored public var onReadyForKeys: (@MainActor () -> Void)?
    /// ``onReadyForKeys`` was reported for this browser.
    @ObservationIgnored var hasDocument = false
    /// The current document is a real page that finished loading, or an error page (not an aborted load).
    @ObservationIgnored var documentLoaded = false
    /// The current document presented its first frame, with or without content (Chromium's `firstPaint` or
    /// `firstContentfulPaint`, `CEFFirstPaintBridge`, or the page's own answer). Chromium drops input to a new document
    /// before its first paint (lead on STATUS 8055: 11 keys sent 4 ms after loading stopped were lost).
    @ObservationIgnored var documentPainted = false
    /// Chromium stopped loading (its last `.loadingState`).
    @ObservationIgnored var loadingStopped = false
    /// The current document is Chromium's error page for a failed load.
    @ObservationIgnored var committedIsErrorPage = false
    /// A first paint came after this load started and before its first commit: it is the committing document's (the
    /// page channel can reach the app before `.loadStart`; lead on STATUS 8132, set 1 a3 waited the whole bound).
    @ObservationIgnored var paintBeforeCommit = false
    /// This load committed a document already (a later commit in the same load is a replacement, painted afresh).
    @ObservationIgnored var committedThisLoad = false
    /// Chromium is loading (its last `.loadingState`).
    @ObservationIgnored var chromiumLoading = false
    /// Whether the current document painted content, asked of the page (``BrowserFirstPaintScript/query``): it waits
    /// for the first contentful paint, and its observer is buffered, so a paint before it asked still counts. Nil: the
    /// call failed or timed out. A test answers instead.
    @ObservationIgnored var paintQuery: @MainActor (CEFTab) async -> Bool? = CEFTab.askPagePainted

    /// The pending ``paintQuery`` of the current document; a commit or the browser's end cancels it.
    @ObservationIgnored var paintAsk: Task<Void, Never>?

    /// The current document loaded and no paint report came: ask the page once whether it painted. Readiness then never
    /// waits on one pushed event that can be lost (#33940: 1 in 43 restores never got Chromium's first contentful paint
    /// event, and the keys waited the whole 2 s bound). A blank target or an error page needs no paint.
    func askPaintIfLoaded() {
        guard !hasDocument, documentLoaded, !documentPainted, !blankIsDocument, !committedIsErrorPage, paintAsk == nil else { return }
        paintAsk = Task { [weak self] in
            guard let self else { return }
            let painted = await paintQuery(self)
            guard !Task.isCancelled else { return } // a later document committed, or the browser ended
            paintAsk = nil
            guard painted == true, !hasDocument else { return }
            host.lifecycleTrace.record(id, "paint-query painted")
            documentPainted = true
            documentMayTakeKeys()
        }
    }

    /// The page's answer to ``BrowserFirstPaintScript/query``.
    private static func askPagePainted(_ tab: CEFTab) async -> Bool? {
        guard let value = try? await tab.evaluate(BrowserFirstPaintScript.query, world: .isolated, gesture: .cmux) else { return nil }
        return value == .bool(true) ? true : nil
    }

    /// The main frame's document presented its first frame (`CEFFirstPaintBridge`): `contentful` for Chromium's
    /// `firstContentfulPaint`, else its `firstPaint` (a frame with no content: an empty field). Either takes keys.
    func documentDidFirstPaint(contentful: Bool = true) {
        // Chromium's own load (its `.loadingState(true)`), not the app's: a load the app asked for before Chromium began
        // it is no load yet, and a paint then is the document before it.
        if !committedThisLoad { paintBeforeCommit = chromiumLoading } else { documentPainted = true }
        if !hasDocument { host.lifecycleTrace.record(id, "cef-first-paint\(contentful ? "" : " frame-only") committed=\(committedThisLoad) loading=\(chromiumLoading)") }
        documentMayTakeKeys()
    }
    /// The document the tab was asked to show is blank (a New Tab page): its blank document counts as loaded.
    @ObservationIgnored var blankIsDocument = false

    func attach(browser: Int32) {
        browserID = browser
        // A page asked to show something (an address, a saved navigation, an agent's load) waits for that document; a
        // page with nothing to load takes keys now (lead on STATUS 7916: a reopen by address is no saved navigation).
        let navigates = pendingURL != nil || pendingRestore != nil || loadAfterAttach != nil
        host.lifecycleTrace.record(id, "ready-wait navigates=\(navigates) url=\(pendingURL != nil) restore=\(pendingRestore != nil) agent=\(loadAfterAttach != nil)")
        (hasDocument, documentLoaded, documentPainted, loadingStopped) = (false, false, false, false)
        (paintBeforeCommit, committedThisLoad, chromiumLoading) = (false, false, false)
        paintAsk?.cancel()
        paintAsk = nil
        blankIsDocument = pendingURL.map { !PageBackground.isRealPage($0) } ?? false
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
        if pageFilesChosen != nil { runtime.applyFileDialogRoute(self) }
        applyDeviceEmulation()
        agentRelay.browserAttached()
        if host.freezesPlaceholder, host.placeholder === self { freezeNeverShownPage(browser) }
        let zoom = machine.state.zoom
        if zoom != 1 { runtime.shim?.setZoomLevel(browser, CEFZoom.level(forFactor: zoom)) }
        // Focus asked for while the page was being created applies only if
        // the page is still shown: CEF's SetFocus activates (orders front)
        // the page window, which for a page that is no longer selected put
        // it back on screen over the pane's current tab.
        let shown = isShown
        host.lifecycleTrace.record(id, "attach pendingFocus=\(pendingFocus) shown=\(shown)")
        if pendingFocus, shown {
            pendingFocus = false
            grantFocus(browser)
        }
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
        runtime.extensionActionReads.refresh(self)
        if !navigates { documentArrived() }
    }

    /// The page asked to show something may take keys: its main frame's document loaded (or is an error page) and
    /// painted content, in either order.
    func documentMayTakeKeys() {
        // The main frame's document loaded and painted (Chrome's own readiness: subframes such as ads may load for
        // seconds after the page shows and takes clicks, review 6594624994). A blank target or an error page paints
        // nothing of its own.
        guard documentLoaded, documentPainted || blankIsDocument || committedIsErrorPage else { return }
        documentArrived()
    }

    /// The page takes keys now: Chromium created it, and (a page asked to show something) its document can take them.
    func documentArrived() {
        guard !hasDocument else { return }
        hasDocument = true
        host.lifecycleTrace.record(id, "ready-for-keys")
        onReadyForKeys?()
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
        paintAsk?.cancel()
        paintAsk = nil
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
        // A tab whose renderer ended while hidden shows the crash notice with its Reload button
        // when shown; only a renderer the system ended for memory reloads, once (`exitRecovery`).
        reloadOwedAfterExit()
    }

    /// Takes the one automatic reload a memory end owes, if the sad tab still shows.
    func reloadOwedAfterExit() {
        guard state.processExit != nil, exitRecovery.takeReload(now: .now) else { return }
        runtime.logger.error("renderer ended tab=\(self.id.rawValue, privacy: .public): reloading once after a memory end")
        reload()
    }

    /// The renderer ended (crash, kill, out of memory, launch failure). The
    /// pane shows the sad tab, now or when the tab is next shown; its Reload
    /// button (or the person's own reload) loads the page again, except that
    /// a renderer the system ended for memory reloads once by itself
    /// (``BrowserExitRecovery``).
    func rendererTerminated(_ exit: BrowserProcessExit) {
        guard !isClosed else { return }
        // A new renderer need not keep the old one's media emulation, so forget
        // what the dead one was told: whichever way the page comes back (Reload
        // from the sad tab), the restarted renderer's
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
        findRequests.cancel()
        let pressure = memoryPressure()
        let owed = exitRecovery.processEnded(exit, pressure: pressure, now: .now)
        runtime.recordRendererExit(exit, tab: self, pressure: pressure, reloads: owed)
        if owed, host.visibleTab === self, !isOccluded { reloadOwedAfterExit() }
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

    public func reload() { reload(bypassingCache: false) }

    /// Hard Reload (``BrowserCacheBypassingReload``): Chrome's Cmd-Shift-R, the entry ignoring the cache.
    public func reloadBypassingCache() { reload(bypassingCache: true) }

    private func reload(bypassingCache: Bool) {
        guard let browserID else {
            if let url = pendingURL ?? state.url { load(url) }
            return
        }
        switch reloadPlan {
        case .reloadEntry:
            if bypassingCache { runtime.shim?.reloadIgnoreCache(browserID) } else { runtime.shim?.reload(browserID) }
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
        let shown = isShown
        host.lifecycleTrace.record(id, "focus(\(focused)) created=\(browserID != nil) shown=\(shown)")
        // Never activate a hidden page's window (see `attach`): a hidden page keeps the ask until it shows.
        let canTake = shown && hasSize
        pendingFocus = focused && (!canTake || browserID == nil)
        guard !focused || canTake, let browserID else { return }
        if focused { grantFocus(browserID) } else { runtime.shim?.setFocus(browserID, 0) }
    }

    /// Whether the page is on screen and may take focus: the pane shows it, the content lifecycle
    /// did not hide it, and its view is in a window under no hidden ancestor. The last part covers a
    /// workspace switch hiding an ancestor: Chromium orders the page window out inside AppKit's hide
    /// walk, before this page's own `viewDidHide` conceals it, and a grant there showed the window
    /// again; the cmux window took the keys back, the focus applier asked again, and the main
    /// thread never left that turn (NIGHTLY 1.0.0-nightly.4093446036501). The ancestors' own
    /// `isHidden` is read, not `isHiddenOrHasHiddenAncestor`: AppKit updates that flag view by view
    /// during the same walk, so a view the walk has not reached yet still reads as not hidden.
    private var isShown: Bool {
        guard host.visibleTab === self, !isOccluded, container.window != nil else { return false }
        return !sequence(first: container as NSView, next: \.superview).contains { $0.isHidden }
    }

    /// The page's host has an area: the CEF fork orders the page window out while its host is empty (as while hidden), so
    /// a grant then orders it in and makes it key for one layout pass (INSTANT OWNER STATUS 14067).
    private var hasSize: Bool { !container.bounds.isEmpty }

    /// Whether the page's window can hold the keys now: shown, with an area, and a browser (``ChildPageFocus``).
    public var canTakeKeys: Bool { isShown && hasSize && browserID != nil }

    /// Keeps a focus ask the page cannot take now; granted once it can (``grantPendingFocusIfShown()``).
    public func keepFocusAsk() { pendingFocus = true }

    /// Grants focus asked for while this page could not take it, once it shows: its view entered a
    /// window (`CEFPaneHost.present`) or the content lifecycle showed it (`setContentVisible`). A
    /// Cmd-N New Tab page (a spare with a browser) asked a moment before it showed and kept no
    /// focus: only a browser's creation used to replay the ask.
    func grantPendingFocusIfShown() {
        guard pendingFocus, isShown, hasSize, !awaitsWindowMove, let browserID else { return }
        // Not while the person types in another window (Cmd-N, then Cmd-` before the page painted):
        // the ask waits until this page's window has the keys again.
        if let key = NSApp.keyWindow, let owner = container.window, key !== owner, key.parent !== owner { return }
        pendingFocus = false
        host.lifecycleTrace.record(id, "focus(pending) granted")
        grantFocus(browserID)
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
        // A hidden page has no pointer over it (Chrome hides the bubble of a background tab).
        if !visible, linkStatus != nil { linkStatus = nil }
        // Show at once; a hide waits for the end of the turn (CEFPaneHost.setNeedsHostVisibility).
        if host.visibleTab === self { if visible { host.hostView.isHidden = false } else { host.setNeedsHostVisibility() } }
        // A DevTools that cmux closed stays hidden until Chromium reports it closed (`closeInThisTurn`).
        devToolsController.views?.host.isHidden = !visible || devToolsController.closing
        if visible { grantPendingFocusIfShown() }
        if visible, host.visibleTab === self { reloadOwedAfterExit() }
    }

    /// Whether the content lifecycle hid this page (read by the pane host
    /// when the tab's content view enters a window).
    var isContentHidden: Bool { isOccluded }

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
        settleTimer.cancel()
        devToolsController.openTimer.cancel()
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
