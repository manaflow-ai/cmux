public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextCompat
import CmuxNextHibernation
import Observation
import os
import CmuxNextErrorJournal
public import WebKit
import CmuxNextTrace
public import CmuxNextWakeups

/// A view that is a cmux page. The key dispatcher reads it to know the focused surface is a page
/// (`surfaceKind == page`); a page view adds no key handling of its own.
@MainActor
public protocol PageSurface: AnyObject {
    var pageID: String { get }
}

/// One React page in a tab or app screen (plans/cmux-next/react-pages.md 1): a transparent WKWebView over the
/// window's one backdrop (windows.md "One backdrop rule"), loading `cmux-page://<id>/` from the bundled page, with
/// the shared web theme (`WebTheme`, from this view's theme scope) and the engine-neutral bridge (``PageHostBridge`` +
/// ``PageRouter``).
///
/// Absorbs the Settings lead's `SettingsWebPageView` (branch feat-cmux-next-settings-react): transparency, the
/// scheme-handler origin, the main-frame and origin check, the debug state and snapshot.
@MainActor
public final class PageWebView: NSView, PageSurface, WKNavigationDelegate {
    public internal(set) var descriptor: PageDescriptor
    /// The engine options the page was made with (``PageEngineOptions``).
    public let engineOptions: PageEngineOptions
    public let router: PageRouter
    /// The WebKit pieces once built: with the view for a WebKit page, only at a fallback for a Chromium
    /// one (PageWebKitEngine.swift). Code outside this module uses the engine-neutral calls or
    /// ``PageWebView/webKitEngine``, which reads this and never builds it.
    var webKitPieces: PageWebKitEngine?
    /// What building the WebKit engine takes.
    let webKitRecipe: PageWebKitRecipe
    /// What the host set for the WebKit view, kept while there is none.
    let webKitHooks = PageWebKitHooks()
    /// Whether the document can take typing yet (the dispatcher's type-ahead).
    public let inputReadiness: PageInputReadiness
    /// Delivers router envelopes in order, rendering large ones off the main actor.
    let scripts: PageScriptPipeline
    /// The bridge the script FIFO and ``pushes`` use: WebKit's, or Chromium's while a Chromium page shows the document.
    let scriptTarget: PageScriptTarget
    /// The engine the page shows in and, for WebKit, why (``PageEnginePolicy``).
    public internal(set) var engineDecision: PageEngineDecision
    /// The Chromium page while one shows the document (PageWebView+Chromium.swift).
    var chromiumSession: PageChromiumSession?
    /// What the page lifecycle froze the page in, nil while it runs (PageWebView+Lifecycle.swift).
    var frozenEngine: PageFrozenEngine? { didSet { if oldValue == nil, frozenEngine != nil { pushes.freezeStarted() } } }
    /// The scripts native code runs in the page, held or thawing it first while it is frozen.
    lazy var pushes = PageNativePushes(self)
    /// Rects in this view's coordinates where native UI of the window shows over the page
    /// (PageWebView+NativeRects.swift): a Chromium page leaves them uncovered. WebKit draws in the
    /// window's own view tree, under that UI, and needs none.
    public var nativeRects: [CGRect] = [] {
        didSet { if nativeRects != oldValue { applyNativeRects() } }
    }
    /// The file of the last drag from outside that entered the Chromium page and that ``fileDrop``
    /// takes, with when it entered; the page's drop opens it once.
    var chromiumDragFile: (url: URL, at: Date)?
    /// Shows the Chromium page's context menu at a point of this view (tests capture it).
    var chromiumMenuPresenter: @MainActor (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Making the Chromium page (cancelled when the view closes or falls back).
    var chromiumStart: Task<Void, Never>?
    /// Set from the Chromium browser's end until the page shows in an engine again or closes (a discard keeps it); a replaced one ends its wait.
    var chromiumRecovery: PageChromiumRecovery? { didSet { if oldValue !== chromiumRecovery { oldValue?.cancel() } } }
    /// The pane window the Chromium page shows in (``PageChromiumWindow``), nil for one of its own. The
    /// pane that shows the page's tab sets it; a new value moves a live page there
    /// (``PageChromiumPage/moveWindow(to:)``), and a page still being made moves once it attaches.
    public var chromiumWindow: PageChromiumWindow? {
        didSet {
            guard let chromiumWindow, chromiumWindow != oldValue else { return }
            chromiumSession?.page.moveWindow(to: chromiumWindow)
        }
    }
    /// How long a Chromium page may take to reach the host before the view falls back to WebKit.
    var chromiumDeadline: Duration = .seconds(8)
    /// Where that deadline runs: the view's ``deadlines`` (a suite that is not about the fallback passes one that
    /// never fires). Read when the Chromium page reaches the host, after the view's first turn; set before then.
    var chromiumDeadlines: MainDeadlineScheduler
    /// The app's one deadline scheduler (``WebUIHost``'s): the claim's fallback, the Chromium
    /// page's deadline and the settings pushes (status look, UI scale) run on it and its ``MainDeadlineScheduler/work``.
    let deadlines: MainDeadlineScheduler
    /// The Chromium host the view was made with (its ``WebUIHost``'s); a discarded page makes its
    /// Chromium page again through it (PageWebView+Discard.swift).
    let chromiumHost: (any PageChromiumHosting)?
    /// What the page keeps for its discard and shows while it comes back (PageWebView+Discard.swift).
    var discardShell = PageDiscardShell()
    /// Makes Chromium pages: a forwarder the app sets once at startup to its ``WebUIHost``'s (``WebUIHost/chromium``), for
    /// views not yet made through ``WebUIHost/open(_:)``; removed by p13-webui-010. Nil keeps every page on WebKit (tests, a build without Chromium).
    public static var chromiumHosting: (any PageChromiumHosting)?
    /// The open panel for a page's `<input type="file">`: a forwarder the app sets once at startup to its ``WebUIHost``'s
    /// (``WebUIHost/openPanel``); removed by p13-webui-010. Nil: a file input does nothing (tests).
    public static var openPanel: MadeAheadOpenPanel?
    /// A discarded page has no document, so it loads nothing until its restore starts a load.
    var loaded = false {
        didSet {
            loadState.set(loading: !loaded && !isDiscarded, page: self)
        }
    }
    /// The document's load as the page lifecycle reads it (its `.loading`); each change tells the lifecycle.
    let loadState = PageLoadState()
    /// The keep reasons its document set (`cmux.page.keepAlive`) and the host holds on it (a
    /// confirmation sheet, a menu or popup, a drop it reads, Web Inspector, dictation); each change
    /// tells the lifecycle.
    package let keepReasons = PageKeepReasons()
    var loadWaiters: [PageLoadWaiter] = []
    var shouldFocusOnAttach = false
    /// The page's popup past the window's edge (PageWebView+Popup.swift), made on first use.
    var popupHost: WebPopupHost?
    /// The windows' frame-aligned pointer input for the page's popup (feature `pointerFrameHover`, the
    /// App's `hoverFrameInput`; ``WebUIHost/open(_:)`` sets it, a preload too): the popup's
    /// rows hover at most twice a frame. Nil: each move.
    public var popupHoverFrameInput: FrameInputCoalescers? {
        didSet { popupHost?.hoverFrameInput = popupHoverFrameInput }
    }
    /// The last theme payload sent, so a redraw that changes nothing sends nothing.
    private var appliedTheme: String?
    /// Pushes every color change of this view's scope to the page, shown or hidden, so a page
    /// shown after a change paints its first frame in the new colors (cx-8w027.12).
    private lazy var themeFollower = ThemeFollower(self) { [weak self] in self?.applyTheme() }
    /// The wallpaper still the page's glass lenses (`cmuxTheme.backdrop`), pushed after each theme and when
    /// the page's place settles (PageWebView+GlassMotion.swift).
    lazy var glassFeed = GlassBackdropFeed(host: self, zoom: { [weak self] in self?.pageZoom ?? 1 }) { [weak self] in self?.pushGlass($0) }
    /// The UI scale and the status look the page follows, shown or hidden (PageWebView+SettingsPushes.swift).
    private var settingsPushes: PageSettingsPushes?
    /// Reduce Motion, the motion switches and the display options (``followAppearance(_:node:)``).
    private var appearanceWatch: AppearanceSignals.Subscription?
    /// Where those come from: the app's ``AppearanceSignals`` (its composition root's, once a pane shows the page).
    private(set) var appearanceSignals = DesignSettings.shared.signals
    /// The page's tab in the visibility tree, held while it follows it (``followAppearance(_:node:)``).
    private(set) var visibilityNode: VisibilityNode?
    /// Whether the engine was last told the page shows (``setEngineVisible(_:)``): in a window and not
    /// hidden. The router's hidden hold starts from it (``deliverOnFrames(_:)``).
    var engineVisible = false
    /// The served web files changed while the page was hidden or frozen (``WebUIHost/webBundleDidChange()``):
    /// it keeps its document, and reloads once it shows and the safe point found that a reload keeps
    /// what it holds (``setEngineVisible(_:)``, ``WebBundleSafePoint``).
    package internal(set) var bundleStale = false
    /// Takes the page when it shows with web files it has not loaded (``bundleStale``): its host sets
    /// it (``WebUIHost/open(_:)``, preloaded pages included). Nil: the page keeps its document until a
    /// swap reloads it.
    weak var bundleSafePoint: (any WebBundleSafePoint)?
    /// How many appearance changes reached this page (tests: a hidden page gets none).
    package private(set) var appearanceCalls = 0
    public var additionalZoom: Double = 1 {
        didSet { if additionalZoom != oldValue { applyUIScale() } }
    }
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")
    /// Answers the page's dynamic prefixes (``PageDescriptor/dynamicPrefixes``); the scheme
    /// handler holds it weakly, so the view keeps it alive.
    var dynamicResources: (any PageDynamicResourceSource)?
    /// True when the page was opened parked for the preload slot (``PageOpenRequest/parked``): its
    /// routes come with its claim (``bindClaim(routes:route:documentAttributes:surface:dynamicResources:)``).
    public let isPooled: Bool
    var pooledOwner: PagePooledOwner?
    /// Whether a pooled host has received real user input (a key or mouse event) since its claim.
    /// Page messages do not count: a parked page mounts when it is shown, so every claim starts
    /// with its own subscriptions and reads; the parking reset drops those and clears storage.
    public internal(set) var touched = false
    /// Prepared page activity does not count as user activity while the view is parked.
    public internal(set) var countsTouches = true
    /// A navigation to any other origin (a link in the page): the host opens it in a browser tab.
    public var onOpenExternal: ((URL) -> Void)?
    /// The modifier keys of the click whose link ``onOpenExternal`` is opening (Shift-Command: the other browser).
    public internal(set) var externalLinkModifiers: NSEvent.ModifierFlags = []
    /// Decides navigations outside the page's origin (``PageNavigation/policy(for:page:userClicked:mainFrame:hook:)``).
    public var onNavigate: ((PageNavigation) -> PageNavigation.Policy)?
    /// The page's web content crashed (or crashed hidden and shows, ``PageCrashRecovery``). `reloading` is false
    /// once its crash budget ran out: the page is not reloaded, and the host shows its notice (with a button
    /// that calls ``reloadAfterCrashes()``). Setting it lets the page share its renderer group's budget.
    public var onCrash: ((PageWebView, _ reloading: Bool) -> Void)?
    /// A main-frame document finished loading, in either engine (WebKit's `didFinish`, Chromium's
    /// load end): after the page's scripts ran, and again after each reload.
    public var onLoaded: (() -> Void)?
    /// The surface whose web theme the page gets (`--cmux-*`; nil: the scope's own), for a page that
    /// shows a surface with its own overrides (the agent pane: new tab page, then agent chat).
    /// `data-*` attributes of `<html>` the host keeps current (`setDocumentAttribute`): set again
    /// on every new document.
    public internal(set) var liveDocumentAttributes: [String: String] = [:]

    public var themeSurface: SurfaceKind? {
        didSet { if themeSurface != oldValue { applyTheme() } }
    }
    /// File drops the host opens itself (``PageFileDrop``); nil gives every drop to the page.
    public var fileDrop: PageFileDrop? {
        get { webKitHooks.fileDrop }
        set { webKitHooks.fileDrop = newValue }
    }
    /// Called with their file URLs when files are dropped on the page itself (not a ``fileDrop`` the
    /// host opens): a real gesture page script can't make.
    public var onFilesDropped: (@MainActor ([URL]) -> Void)? {
        get { webKitHooks.onFilesDropped }
        set { webKitHooks.onFilesDropped = newValue }
    }
    /// Called when a paste (Cmd-V, Edit > Paste) is about to reach the page, before WebKit pastes.
    public var onPaste: (@MainActor () -> Void)? {
        get { webKitHooks.onPaste }
        set { webKitHooks.onPaste = newValue }
    }
    /// When a real key or mouse event last reached the page (`systemUptime`; page script cannot set
    /// it), the event behind `PageCallContext.userGesture`. A host that grants one action per
    /// gesture (a file page's "Open <path>?" sheet) records the value it used.
    public var lastUserEventUptime: TimeInterval? {
        chromiumSession != nil ? chromiumUserEventUptime : webKitPieces?.view.lastUserEventUptime
    }
    /// When a real key or mouse event last reached the Chromium page (``PageChromiumEvent/userInput(_:)``).
    var chromiumUserEventUptime: TimeInterval?
    /// The host's extra message handlers (``addMessageHandler(_:handler:)``), for a Chromium page.
    var chromiumMessageHandlers: [String: @MainActor (Any) -> Void] = [:]
    /// Runs before the host builds a Chromium page's right-click menu: a host whose menu depends on
    /// a report the page sends on `contextmenu` (the agent chat) waits for it here, since Chromium's
    /// menu request and the page's message arrive in either order. Nil builds the menu at once.
    public var chromiumMenuWait: (@MainActor () async -> Void)?
    /// The crash clock (tests set it).
    var now: () -> Date = { Date() }
    let crash = PageCrashRecovery()
    let claimState: PageClaimState
    /// The document start a page opened hidden waits with until its first show (PageWebView+FirstShow.swift).
    var firstShowStart: PageFirstShowStart?
    /// The visibility node a page waiting for its first show follows (PageWebView+FirstShow.swift).
    var firstShowWatch: PageFirstShowWatch?
    /// The picture and state kept from the page's last hide (PageWebView+Snapshot.swift).
    package let hideState = PageHideState()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// What `debug.webui` knows of this page (PageWebView+Debug.swift).
    var censusState = PageCensusState()
    #endif

    public var pageID: String { descriptor.id }

    /// Nil when the page is missing from the resource bundle and no root is registered for it
    /// (``PageID/registerBundledRoot(_:for:)``).
    public convenience init?(descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                             documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                             surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil,
                             deadlines: MainDeadlineScheduler) {
        self.init(request: PageOpenRequest(descriptor: descriptor, routes: routes, route: route,
                                           documentAttributes: documentAttributes, options: options,
                                           surface: surface, dynamicResources: dynamicResources),
                  chromium: Self.chromiumHosting, openPanel: Self.openPanel, registry: .processWide, deadlines: deadlines)
    }

    /// The root a page is served from without an explicit one: the DEBUG override, else this
    /// module's bundled directory, else the root registered for its id.
    nonisolated static func servedRoot(for descriptor: PageDescriptor) -> URL? {
        debugRoot(for: descriptor) ?? PageSchemeHandler.bundledRoot(for: descriptor) ?? PageID.bundledRoot(for: descriptor.id)
    }

    /// The DEBUG root override of a page (`CMUX_NEXT_PAGE_ROOT_cmux_history=/path`), else nil.
    nonisolated static func debugRoot(for descriptor: PageDescriptor) -> URL? {
        #if DEBUG
        let name = "CMUX_NEXT_PAGE_ROOT_" + descriptor.id.replacingOccurrences(of: ".", with: "_")
        return ProcessInfo.processInfo.environment[name].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        return nil
        #endif
    }

    /// Whether `descriptor` may be served from `root`: any root for an app page; for a first-party
    /// page only its bundled root or its DEBUG override.
    nonisolated static func mayServe(_ descriptor: PageDescriptor, from root: URL) -> Bool {
        guard PageID.isReserved(descriptor.id) else { return true }
        let wanted = root.standardizedFileURL.resolvingSymlinksInPath().path
        let allowed = [PageSchemeHandler.bundledRoot(for: descriptor), PageID.bundledRoot(for: descriptor.id),
                       debugRoot(for: descriptor)].compactMap { $0 }
        return allowed.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == wanted }
    }

    /// `root` is the directory that holds the page's `index.html`. A first-party page (``PageID``)
    /// is served only from its bundled root, so nothing else can be served under a first-party
    /// origin; DEBUG builds may point one at another root (`CMUX_NEXT_PAGE_ROOT_<id>`, dots as
    /// underscores) for the page dev loop. Nil when that check fails.
    ///
    /// `documentAttributes` become `data-*` attributes of `<html>` before the page's code runs (the
    /// page's init: `["cloud-machines-layout": "cards"]` is `data-cloud-machines-layout`).
    ///
    /// `options` are engine options (``PageEngineOptions``); each engine maps the ones it has.
    /// `surface` is the initial ``themeSurface`` (the diff page passes `.diff`, so
    /// `appearance.surfaces.diff` reaches `--cmux-surface-background`); `dynamicResources` answers
    /// the descriptor's dynamic prefixes (a 404 without one).
    ///
    /// `chromium` makes the page's Chromium view when the policy picks Chromium (the app's
    /// ``chromiumHosting`` by default; tests pass a fake).
    public convenience init?(descriptor: PageDescriptor, root: URL, routes: [PageRoute], route: String? = nil,
                             documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                             surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil,
                             chromium: (any PageChromiumHosting)? = PageWebView.chromiumHosting, deadlines: MainDeadlineScheduler) {
        self.init(request: PageOpenRequest(descriptor: descriptor, root: root, routes: routes, route: route,
                                           documentAttributes: documentAttributes, options: options,
                                           surface: surface, dynamicResources: dynamicResources),
                  chromium: chromium, openPanel: Self.openPanel, registry: .processWide, deadlines: deadlines)
    }

    init(descriptor: PageDescriptor, configuration: WKWebViewConfiguration,
         inputReadiness: PageInputReadiness, routes: [PageRoute], route: String?, options: PageEngineOptions,
         surface: SurfaceKind?, dynamicResources: (any PageDynamicResourceSource)?, pooled: Bool, load: Bool,
         openRequested: TimeInterval? = nil, chromium: (any PageChromiumHosting)? = PageWebView.chromiumHosting,
         openPanel: MadeAheadOpenPanel? = PageWebView.openPanel, registry: PageRegistry = .processWide,
         processGroup: PageWebKitProcessGroup? = nil, startsAtFirstShow: Bool = false,
         deadlines: MainDeadlineScheduler,
         trace: any PageTraceSink = TraceRuntime.shared, chatOpen: ChatOpenStages? = nil, origin: PageOpenOrigin = .user) {
        let constructionStart = openRequested ?? ProcessInfo.processInfo.systemUptime
        self.deadlines = deadlines
        chromiumDeadlines = deadlines
        claimState = PageClaimState(deadlines: deadlines)
        self.trace = trace
        self.chatOpen = chatOpen
        self.descriptor = descriptor
        chromiumHost = chromium
        engineOptions = options
        isPooled = pooled
        pooledOwner = nil
        themeSurface = surface
        self.dynamicResources = dynamicResources
        router = PageRouter(descriptor: descriptor, routes: routes)
        webKitRecipe = PageWebKitRecipe(configuration: configuration, processGroup: processGroup, openPanel: openPanel)
        self.inputReadiness = inputReadiness
        let decision = Self.engineDecision(for: descriptor, options: options, hosting: chromium)
        let decided = !load ? decision.webKitOnly : decision
        engineDecision = decided
        // A Chromium page the launch restored waits for its show or launch turn (``PageOpenOrigin/launchRestore``), as one
        // that starts at its first show does; until it starts it sends no script (``PageScriptTarget/hasDocument``).
        let restoredAtLaunch = load && origin == .launchRestore && decided.engine == .cef && chromium?.holdsRestoredPages == true
        let waits = load && (startsAtFirstShow || restoredAtLaunch)
        // No script until the page starts; the engine that shows the document sets the bridge.
        let target = PageScriptTarget(hasDocument: !waits)
        scriptTarget = target
        scripts = PageScriptPipeline(deliver: { target.deliver($0) }, form: { target.deliveryForm }) // MQ12 held queue: the router holds envelopes while hidden
        super.init(frame: .zero)
        // A WebKit page builds its engine now; a Chromium page only when it falls back.
        if engineDecision.engine != .cef { _ = webKit }
        SystemScrollers.observe(self) { [weak self] _ in self?.applyTheme() } // theme carries data-scrollers
        observeAppearance()
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        settingsPushes = PageSettingsPushes(self, on: deadlines.work) // applies the current scale and look now
        registry.add(self)
        let scripts = scripts
        router.send = { envelope in scripts.send(envelope) }
        router.sendWithDrop = { envelope, onDrop in scripts.send(envelope, onDrop: onDrop) }
        keepReasons.owner = self
        router.didClose = { [weak self] in
            scripts.reset()
            self?.popupHost?.hide()
            // A reload, a crash, a navigation or a rebind: the document's own reasons end with it.
            self?.keepReasons.documentEnded()
        }
        router.keepAlive = { [weak self] reason, on in self?.keepReasons.setFromPage(reason, on: on) }
        router.titleBarDoubleClick = { [weak self] in self?.performTitleBarDoubleClick() }
        router.popup = { [weak self] op, params in self?.popup(op, params: params) ?? .object(["shown": .bool(false)]) }
        router.contextMenu = { [weak self] params in await self?.contextMenu(params) ?? .object(["picked": .null]) }
        router.userGestureEvent = { [weak self] in self?.recentUserGestureEvent() }
        #if DEBUG || CMUX_BENCH_HOOKS
        noteCensusVisibility(false) // in no window yet (`debug.webui`)
        #endif
        // Console errors, uncaught errors and rejections go to the error journal (`cmux errors`).
        ConsoleErrorCapture(page: descriptor.id).install(in: configuration.userContentController)
        PagePaintProbe.install(in: configuration.userContentController) { [weak self] in
            self?.notePainted()
        }
        installPageStateSave()
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        installDocumentStartTheme()
        guard load else { return }
        let start = PageFirstShowStart(chromium: chromium, requested: constructionStart, opener: origin,
                                       atLaunchTurn: restoredAtLaunch && !startsAtFirstShow)
        // A view is in no window while it is made: one opened to show starts at its pane's attach
        // in this turn; one opened hidden makes no renderer until it shows (a restored one: or its launch turn).
        if waits { firstShowStart = start } else { startDocument(start, origin: start.chromiumOrigin(shown: false)) }
    }

    /// The current document painted its first frame (``PagePaintProbe``, either engine).
    func notePainted() {
        removeStandIn()
        traceMark(.pagePainted)
        paintedUptime = ProcessInfo.processInfo.systemUptime
        traceOpenEnd(showsChromium ? .paintedInChromium : .paintedInWebKit)
        let waiters = paintWaiters
        paintWaiters = []
        waiters.forEach { $0() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Follows `signals` by `node`'s visibility (p06-scheduler.md B): a hidden page re-themes once
    /// when it shows, not on each change. The pane that shows the page calls it
    /// (`TabContent.followAppearance`).
    public func followAppearance(_ signals: AppearanceSignals, node: VisibilityNode?) {
        guard signals !== appearanceSignals || node !== visibilityNode else { return }
        appearanceSignals = signals
        visibilityNode = node
        observeAppearance()
        applyTheme()
        checkFirstShow() // the tab's node now says whether the page shows
    }

    /// Reduce Motion, the master motion switch, a category switch or the speed (`data-cmux-motion`),
    /// and Reduce Transparency (the opaque page background, ``currentTheme(backgrounds:)``).
    private func observeAppearance() {
        appearanceWatch = appearanceSignals.subscribe([.motion, .displayOptions], viewNode: visibilityNode, owner: "PageWebView") { [weak self] in
            guard let self else { return }
            appearanceCalls += 1
            applyTheme()
        }
    }

    /// Page zoom follows `uiScale`; the chrome multiplier is only the `--cmux-interface-scale` token.
    func applyUIScale() {
        webKitPieces?.view.pageZoom = pageZoom
        chromiumSession?.page.setZoom(pageZoom)
        pushes.run(DesignSettings.shared.interfaceScaleScript, whileFrozen: .latest(.interfaceScale))
        if loaded { glassFeed.refresh() } // the zoom moves the art's rect in CSS px
        repaintStandIn() // its title is zoomed as the page's text is
    }

    /// Marks a claimed pooled host as used by real input.
    func noteTouch() {
        if countsTouches { touched = true }
    }

    /// The window's title bar double-click action (System Settings > Desktop & Dock: zoom by
    /// default, minimize, or nothing), for a title bar the page draws (DESKTOP-FEEL).
    func performTitleBarDoubleClick() {
        WindowTitlebar.performDoubleClick(in: window)
    }

    nonisolated public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        webKitPieces?.view.frame = bounds
        if let standIn { PageStandInLayer.withoutActions { standIn.frame = bounds } }
        glassFeed.hostDidLayout()
        layoutDiscardCover()
        if !nativeRects.isEmpty { applyNativeRects() } // the unflipped Chromium view's rects move with the height
        // Not while the claim is pending: a refused document reloads, and its paint would end the
        // pane's hold before the reloaded one drew (finishClaim runs the probe on acknowledgement).
        if repaintsAtNextLayout, !claimState.pending, window != nil, !bounds.isEmpty, !isParkedSpare {
            repaintsAtNextLayout = false
            pushes.run(PagePaintProbe.script, whileFrozen: .latest(.paintProbe))
        }
    }

    /// The fragment the host last asked the page to show (``open(route:)``); the page may move on
    /// by itself (its own links and history).
    public internal(set) var route: String?

    /// Shows `route` (the URL fragment) in the page.
    public func open(route: String) {
        let fragment = route.hasPrefix("#") ? route : "#" + route
        self.route = fragment
        // A discarded page loads the route when it comes back; it has no document to show it in now.
        if isDiscarded { return }
        guard loaded else {
            // Not started yet (Chromium's page on its way, or the first show): it loads `route` when it starts.
            if firstShowStart != nil || (engineDecision.engine == .cef && chromiumSession == nil) { return }
            loadDocument(descriptor.url(route: fragment))
            return
        }
        pushes.run("window.location.hash = \(JSONValue.string(fragment).compactText);", whileFrozen: .latest(.route))
    }

    /// Sends a dispatcher command (`find` with optional `text`, `focusSearch`, `back`, `forward`,
    /// `reset`) on the page's command stream. False when no page code listens.
    @discardableResult
    public func send(command: String, arguments: [String: JSONValue] = [:]) -> Bool {
        router.publishCommand(command, arguments: arguments)
    }

    /// The page's owner link (the daemon) went up or down; the page shows its disconnected state.
    public func setConnected(_ connected: Bool) {
        router.publishConnection(connected)
    }

    /// Reloads the page document (its subscriptions end with the old document).
    public func reload() {
        // A page not started yet loads fresh at its first show, and a discarded one when it shows
        // again: neither has a document to reload now.
        guard firstShowStart == nil, !isDiscarded else { return }
        reloadPage()
    }

    /// Gives the page the keyboard focus: while its Chromium page starts, this view holds it until the page attaches.
    public func focusPage() {
        if let chromiumSession { return chromiumSession.page.setFocused(true) }
        window?.makeFirstResponder(focusView)
    }

    /// Only a Chromium page on its way, with no engine view yet, takes the keyboard itself (``focusView``).
    public override var acceptsFirstResponder: Bool { webKitPieces == nil && chromiumSession == nil }

    /// When the current document painted its first frame (``PagePaintProbe``), in
    /// `ProcessInfo.systemUptime` seconds; nil until it has.
    public internal(set) var paintedUptime: TimeInterval?
    public var hasPainted: Bool { paintedUptime != nil }
    /// Callbacks for the current document's first frame (`whenPainted`).
    var paintWaiters: [() -> Void] = []
    /// The cold open's stand-in, over the page until its first frame (``showStandIn(title:)``).
    var standIn: PageStandInLayer?
    /// A ``SignpostName/webuiOpen`` slice is open until the document's first paint (`traceOpenEnd`).
    var openTracePending = false
    /// Where the `webui.open` slices go (``PageTraceSink``).
    let trace: any PageTraceSink
    /// The agent chat open this page shows (its stages go there, ``traceMark(_:)``); nil for every other page and
    /// for one made with no open (a prewarmed page gets the open that adopts it).
    public var chatOpen: ChatOpenStages?
    /// A claimed preload painted while parked, maybe at another size: it counts as painted again
    /// only once it drew at its own size (``bindClaim(routes:route:documentAttributes:surface:dynamicResources:)``, ``layout()``).
    var repaintsAtNextLayout = false

    func receive(_ message: PageHostMessage) async -> Any? {
        guard PageHostTrust.isTrusted(message, page: descriptor) else {
            logger.error("page \(self.descriptor.id, privacy: .public) message from an untrusted frame refused")
            return nil
        }
        // The message conversion stays here: `handle` must start in the order the page posted, and
        // `message.body` is a non-Sendable WebKit object graph (page messages are small calls).
        guard let body = JSONValue(foundation: message.body) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let reply = await router.handle(body)
        let handled = ProcessInfo.processInfo.systemUptime
        defer { Self.noteSlowReply(body, page: descriptor.id, started: started, handled: handled, logger: logger) }
        // The reply reaches the page after the events sent before it and before the events sent
        // after it (a subscribe's reply names the sub its first events use). A gate holds the
        // script FIFO here while those earlier events drain and a large reply converts off main.
        let large = !reply.isNull && !reply.fits(PageScriptPipeline.inlineBudget)
        let gate = scripts.gate(always: large)
        defer { gate?.open() }
        await gate?.reached()
        if reply.isNull { return nil }
        guard large else { return reply.foundationObject }
        return await PageReplyObject.convert(reply).object
    }

    /// A page message whose reply took over a second: its op, the router's time and the time the
    /// reply then waited for the page's script FIFO (a reply the page never gets looks the same
    /// from the page as a call the host never answered).
    private static func noteSlowReply(_ body: JSONValue, page: String, started: TimeInterval, handled: TimeInterval, logger: Logger) {
        let done = ProcessInfo.processInfo.systemUptime
        guard done - started > 1 else { return }
        let op = body["op"]?.stringValue ?? body["t"]?.stringValue ?? "?"
        logger.info("page \(page, privacy: .public) \(op, privacy: .public): handled in \(Int((handled - started) * 1000)) ms, replied after \(Int((done - started) * 1000)) ms")
    }

    // MARK: Theme

    // The page's colors follow this view's theme scope (room, workspace), resolved in the hooks
    // that run again on every theme change.
    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = nil
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Its tab or window closed: the page's popup ends with it.
        if window == nil { popupHost?.dismiss() }
        // visibility-walk-allow: the engine's visibility is the AppKit state its view shows in (the freeze guard reads the same); one walk per window move
        setEngineVisible(window != nil && !isHiddenOrHasHiddenAncestor)
        checkFirstShow()
        applyTheme()
        windowDidChangeChrome()
        if shouldFocusOnAttach, window != nil {
            shouldFocusOnAttach = false
            focusPage()
        }
    }

    /// Another tab took the pane: the page's popup ends.
    // visibility-walk-allow: AppKit's hide is the engine's own visibility signal (WebKit and Chromium throttle the page from it), not hidden-dirty view work; a popup over a hidden page ends
    public override func viewDidHide() {
        super.viewDidHide()
        popupHost?.dismiss()
        setEngineVisible(false)
    }

    // visibility-walk-allow: AppKit's unhide is the engine's own visibility signal, and the first show starts the document (checkFirstShow); no hidden-dirty view work
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        setEngineVisible(window != nil)
        checkFirstShow()
    }

    // visibility-walk-allow: the theme push must reach the page shown or hidden, so its first frame after a show paints in the new colors (ThemeFollower's rule); an unchanged payload sends nothing
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        themeFollower.rebind()
        // A move between containers of one window calls no window or unhide callback.
        checkFirstShow()
    }

    func applyTheme(force: Bool = false) {
        themeFollower.rebind()
        repaintStandIn()
        guard loaded else { return }
        let theme = currentTheme()
        if force || theme.payloadJSON != appliedTheme {
            appliedTheme = theme.payloadJSON
            pushes.run(theme.applyScript, whileFrozen: .latest(.theme))
        }
        // After the theme, which sets `data-glass`; a forced push is a new document, which has no still yet.
        glassFeed.refresh(newDocument: force)
    }

    /// The page theme from this view's scope and ``themeSurface``: the surface's override (from
    /// `backgrounds`, the app's) replaces the page background; nil keeps the scope's own.
    func currentTheme(backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> WebTheme {
        WebTheme(themeTokens, reduceTransparency: appearanceSignals.display.reduceTransparency,
                 surface: themeSurface ?? .internalPage, backgrounds: backgrounds)
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        switch PageNavigation.policy(for: url, page: descriptor, userClicked: action.navigationType == .linkActivated,
                                     mainFrame: action.targetFrame?.isMainFrame ?? true, hook: onNavigate) {
        case .allow:
            return .allow
        case .openExternal:
            // A page whose host routes nothing itself (Settings, What's New, Cloud, Keybindings...)
            // opens the link through the shared rule; Shift-Command asks for the other browser.
            externalLinkModifiers = action.modifierFlags
            let other = LinkRouter.isOtherTarget(action.modifierFlags)
            if let url {
                if let onOpenExternal { onOpenExternal(url) } else { LinkRouter.shared.open(url, otherTarget: other, from: self) }
            }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

}
