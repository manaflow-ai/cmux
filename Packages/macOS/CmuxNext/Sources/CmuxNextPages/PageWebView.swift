public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextCompat
import Observation
import os
import CmuxNextErrorJournal
public import WebKit
import CmuxNextWakeups

/// A view that is a cmux page. The key dispatcher reads it to know the focused surface is a page
/// (`surfaceKind == page`); a page view adds no key handling of its own.
@MainActor
public protocol PageSurface: AnyObject {
    var pageID: String { get }
}

/// One React page in a tab or app screen (plans/cmux-next/react-pages.md 1): a transparent
/// WKWebView over the window's one backdrop (windows.md "One backdrop rule"), loading
/// `cmux-page://<id>/` from the bundled page, with the shared web theme (`WebTheme`, from this
/// view's theme scope) and the
/// engine-neutral bridge (``PageHostBridge`` + ``PageRouter``).
///
/// Absorbs the Settings lead's `SettingsWebPageView` (branch feat-cmux-next-settings-react):
/// transparency, the scheme-handler origin, the main-frame and origin check, the debug state and
/// snapshot.
@MainActor
public final class PageWebView: NSView, PageSurface, WKNavigationDelegate {
    public internal(set) var descriptor: PageDescriptor
    /// The engine options the page was made with (``PageEngineOptions``).
    public let engineOptions: PageEngineOptions
    public let router: PageRouter
    let webView: PageWKWebView
    public var webKitView: WKWebView { webView }
    /// Whether the document can take typing yet (the dispatcher's type-ahead).
    public let inputReadiness: PageInputReadiness
    /// The WebKit bridge (installed on every view, so a Chromium page can fall back at once).
    let bridge: any PageHostBridge
    /// Delivers router envelopes in order, rendering large ones off the main actor.
    let scripts: PageScriptPipeline
    /// The bridge the script FIFO and ``evaluateInPage(_:)`` use: WebKit's, or Chromium's while a
    /// Chromium page shows the document.
    let scriptTarget: PageScriptTarget
    /// The engine the page shows in and, for WebKit, why (``PageEnginePolicy``).
    public internal(set) var engineDecision: PageEngineDecision
    /// The Chromium page while one shows the document (PageWebView+Chromium.swift).
    var chromiumSession: PageChromiumSession?
    /// Rects in this view's coordinates where native UI of the window shows over the page
    /// (PageWebView+NativeRects.swift): a Chromium page leaves them uncovered. WebKit draws in the
    /// window's own view tree, under that UI, and needs none.
    public var nativeRects: [CGRect] = [] {
        didSet { if nativeRects != oldValue { applyNativeRects() } }
    }
    /// Called after the page's effective visibility changes. Owners use this to revoke native
    /// page proofs on hide/detach and rebind them after the Chromium document is visible again.
    public var onVisibilityChanged: (@MainActor (Bool) -> Void)?
    /// The Chromium host this page started in: told when its Chromium page attached
    /// (``PageChromiumHosting/focusViewChanged(_:)``).
    weak var chromiumFocusHost: (any PageChromiumHosting)?
    /// The Chromium execution context behind the isolated question-key channel was destroyed.
    /// Owners clear their cached binding and refresh it against the new document context.
    public var onQuestionKeyChannelInvalidated: (@MainActor () -> Void)?
    /// The file of the last drag from outside that entered the Chromium page and that ``fileDrop``
    /// takes, with when it entered; the page's drop opens it once.
    var chromiumDragFile: (url: URL, at: Date)?
    /// Shows the Chromium page's context menu at a point of this view (tests capture it).
    var chromiumMenuPresenter: @MainActor (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        // A view in no window cannot anchor a menu (AppKit raises): the page closed meanwhile.
        guard view.window != nil else { return }
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Making the Chromium page (cancelled when the view closes or falls back).
    var chromiumStart: Task<Void, Never>?
    /// How long a Chromium page may take to reach the host before the view falls back to WebKit.
    var chromiumDeadline: Duration = .seconds(8)
    /// The deadline's clock (tests pass one that returns at once or never).
    var chromiumClock: any Clock<Duration> = ContinuousClock()
    /// Makes Chromium pages; the app sets it once at startup (its composition root). Nil keeps every
    /// page on WebKit (tests, a build without Chromium).
    public static var chromiumHosting: (any PageChromiumHosting)?
    /// The app's made-ahead open panel for a page's `<input type="file">`; the app sets it once at startup with
    /// ``chromiumHosting`` (its composition root). Nil: a file input does nothing (tests).
    public static var openPanel: MadeAheadOpenPanel?
    /// This page's file chooser (its web view holds the UI delegate weakly).
    private(set) var fileChooser: PageOpenPanel?
    var loaded = false
    /// The tab closed (``close()``): its web view is retired and never loads again.
    var isClosed = false
    var loadWaiters: [CheckedContinuation<Void, Never>] = []
    var shouldFocusOnAttach = false
    /// The page's popup past the window's edge (PageWebView+Popup.swift), made on first use.
    var popupHost: WebPopupHost?
    /// The last theme payload sent, so a redraw that changes nothing sends nothing.
    private var appliedTheme: String?
    /// Pushes every color change of this view's scope to the page, shown or hidden, so a page
    /// shown after a change paints its first frame in the new colors (cx-8w027.12).
    private lazy var themeFollower = ThemeFollower(self) { [weak self] in self?.applyTheme() }
    /// The wallpaper still the page's glass lenses (`cmuxTheme.backdrop`), pushed after each theme.
    private lazy var glassFeed = GlassBackdropFeed(host: self, zoom: { [weak self] in self?.pageZoom ?? 1 }) { [weak self] in self?.evaluateInPage($0) }
    private var uiScaleObservation: Task<Void, Never>?
    /// The static status look (`WebTheme.statusIndicators`): the setting and Reduce Motion.
    private var statusLookObservation: Task<Void, Never>?
    private var reduceMotionObservers: [MainActorObservation] = []
    public var additionalZoom: Double = 1 {
        didSet { if additionalZoom != oldValue { applyUIScale() } }
    }
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")
    /// Answers the page's dynamic prefixes (``PageDescriptor/dynamicPrefixes``); the scheme
    /// handler holds it weakly, so the view keeps it alive.
    var dynamicResources: (any PageDynamicResourceSource)?
    /// True when this view came from ``PageHostPool`` and may be rebound to another bundled page.
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
    /// The page's web content crashed. `reloading` is false once it crashed more often than
    /// ``PageCrashReloads`` allows: the page is not reloaded, and the host shows its notice (with a
    /// button that calls ``reloadAfterCrashes()``).
    public var onCrash: ((PageWebView, _ reloading: Bool) -> Void)?
    /// A document finished loading in the page (either engine): the page lives, so a host that
    /// shows a crash notice for it takes the notice away (a host route, a retarget or a WebKit
    /// fallback can load the page again without the notice's Reload).
    public var onDocumentLoaded: (@MainActor () -> Void)?
    /// Why the last crash reported to ``onCrash`` ended the page's process (WebKit's reason and
    /// pid); nil before any crash.
    public internal(set) var lastTermination: PageTermination?
    /// The last WebContent pid seen at a finished load: WebKit may report 0 for a process that ended.
    var knownWebContentPid: Int32 = 0
    /// Whether a crashed page reloads by itself (up to ``PageCrashReloads/limit``). A host whose page
    /// holds the person's state (the agent chat: an open menu, the caret, an IME composition) sets it
    /// false: every crash shows its notice, and only its Reload button reloads.
    public var reloadsAfterCrash = true
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
        get { (webView as? PageWKWebView)?.fileDrop }
        set { (webView as? PageWKWebView)?.fileDrop = newValue }
    }
    /// Called with their file URLs when files are dropped on the page itself (not a ``fileDrop`` the
    /// host opens): a real gesture page script can't make.
    public var onFilesDropped: (@MainActor ([URL]) -> Void)? {
        get { (webView as? PageWKWebView)?.onFilesDropped }
        set { (webView as? PageWKWebView)?.onFilesDropped = newValue }
    }
    /// Called with their file URLs when the person picks files in the page's file input
    /// (``PageOpenPanel``), before the page gets them: a pick page script can't make.
    public var onFilesChosen: (@MainActor ([URL]) -> Void)? {
        get { fileChooser?.onChosen }
        set { fileChooser?.onChosen = newValue }
    }
    /// Called when a paste (Cmd-V, Edit > Paste) is about to reach the page, before WebKit pastes.
    public var onPaste: (@MainActor () -> Void)? {
        get { (webView as? PageWKWebView)?.onPaste }
        set { (webView as? PageWKWebView)?.onPaste = newValue }
    }
    /// When a real key or mouse event last reached the page (`systemUptime`; page script cannot set
    /// it), the event behind `PageCallContext.userGesture`. A host that grants one action per
    /// gesture (a file page's "Open <path>?" sheet) records the value it used.
    public var lastUserEventUptime: TimeInterval? {
        chromiumSession != nil ? chromiumUserEventUptime : (webView as? PageWKWebView)?.lastUserEventUptime
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
    var crashReloads = PageCrashReloads()
    /// Chromium ended under a host that shows the crash notice: the page reopens in WebKit only on
    /// the notice's Reload (``reloadAfterCrashes()``).
    var webKitLoadsOnReload = false
    let claimState = PageClaimState()

    public var pageID: String { descriptor.id }

    /// Nil when the page is missing from the resource bundle and no root is registered for it
    /// (``PageID/registerBundledRoot(_:for:)``).
    public convenience init?(descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                             documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                             surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil) {
        guard let root = Self.servedRoot(for: descriptor) else { return nil }
        let handler = PageSchemeHandler(page: descriptor, root: root, dynamicSource: dynamicResources)
        let host = Self.hostConfiguration(handler: handler, documentAttributes: documentAttributes, options: options)
        self.init(descriptor: descriptor, configuration: host.configuration, inputReadiness: host.inputReadiness,
                  routes: routes, route: route, options: options, surface: surface,
                  dynamicResources: dynamicResources, pooled: false, load: true)
    }

    /// The root a page is served from without an explicit one: the DEBUG override, else this
    /// module's bundled directory, else the root registered for its id.
    nonisolated static func servedRoot(for descriptor: PageDescriptor) -> URL? {
        debugRoot(for: descriptor) ?? PageSchemeHandler.bundledRoot(for: descriptor) ?? PageID.bundledRoot(for: descriptor.id)
    }

    /// The script that sets `data-<name>` attributes on `<html>`; nil for none. Names keep only
    /// lowercase letters, digits and dashes; values are JSON string literals.
    ///
    /// WebKit runs a document-start script once `<html>` exists, but Chromium runs a new-document
    /// script (``PageChromiumDocumentScripts``) before the parser makes it, when
    /// `document.documentElement` is null: setting the attributes then threw, and a Chromium page
    /// (the agent chat by default) got none of them, so `data-needs-you="off"` never hid Needs you.
    /// Without `<html>` the script waits for it with a MutationObserver, whose callback runs before
    /// the page's first script.
    nonisolated static func attributesScript(_ attributes: [String: String]) -> String? {
        let safe = attributes.filter { name, _ in !name.isEmpty && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } }
        guard !safe.isEmpty else { return nil }
        let lines = safe.keys.sorted().map { name in
            "document.documentElement.setAttribute(\(JSONValue.string("data-" + name).compactText), \(JSONValue.string(safe[name] ?? "").compactText));"
        }
        return """
        (() => {
        const set = () => {
        \(lines.joined(separator: "\n"))
        };
        if (document.documentElement) { set(); return; }
        new MutationObserver((_, observer) => {
          if (!document.documentElement) return;
          observer.disconnect();
          set();
        }).observe(document, { childList: true });
        })();
        """
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
    /// page only its bundled root or its DEBUG override, or in DEBUG a `testRoot`.
    nonisolated static func mayServe(_ descriptor: PageDescriptor, from root: URL, testRoot: Bool = false) -> Bool {
        guard PageID.isReserved(descriptor.id) else { return true }
        #if DEBUG
        if testRoot { return true }
        #endif
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
    /// `testRoot` (DEBUG only; a Release build ignores it): `root` is a test's own fixture, served for a
    /// reserved page too. `swift test` links every test target into one process, so the page's registered
    /// root (``PageID/registerBundledRoot(_:for:)``, the first wins) may be another test's.
    ///
    /// `chromium` makes the page's Chromium view when the policy picks Chromium (the app's
    /// ``chromiumHosting`` by default; tests pass a fake).
    public convenience init?(descriptor: PageDescriptor, root: URL, testRoot: Bool = false, routes: [PageRoute], route: String? = nil,
                             documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                             surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil,
                             chromium: (any PageChromiumHosting)? = PageWebView.chromiumHosting) {
        guard Self.mayServe(descriptor, from: root, testRoot: testRoot) else { return nil }
        let host = Self.hostConfiguration(handler: PageSchemeHandler(page: descriptor, root: root,
                                                                       dynamicSource: dynamicResources),
                                          documentAttributes: documentAttributes, options: options)
        self.init(descriptor: descriptor, configuration: host.configuration, inputReadiness: host.inputReadiness,
                  routes: routes, route: route, options: options, surface: surface,
                  dynamicResources: dynamicResources, pooled: false, load: true, chromium: chromium)
    }

    init(descriptor: PageDescriptor, configuration: WKWebViewConfiguration,
         inputReadiness: PageInputReadiness, routes: [PageRoute], route: String?, options: PageEngineOptions,
         surface: SurfaceKind?, dynamicResources: (any PageDynamicResourceSource)?, pooled: Bool, load: Bool,
         chromium: (any PageChromiumHosting)? = PageWebView.chromiumHosting) {
        self.descriptor = descriptor
        engineOptions = options
        isPooled = pooled
        pooledOwner = nil
        themeSurface = surface
        self.dynamicResources = dynamicResources
        router = PageRouter(descriptor: descriptor, routes: routes)
        self.inputReadiness = inputReadiness
        // webview-allow: the page host's WebKit engine; PageEnginePolicy picks it
        webView = PageWKWebView(frame: .zero, configuration: configuration)
        inputReadiness.attach(webView)
        let webKitBridge = WebKitPageHostBridge(webView: webView)
        bridge = webKitBridge
        let target = PageScriptTarget(webKitBridge)
        scriptTarget = target
        scripts = PageScriptPipeline { script in target.evaluate(script) }
        let decision = Self.engineDecision(for: descriptor, options: options, hosting: chromium)
        engineDecision = pooled || !load ? decision.webKitOnly : decision
        super.init(frame: .zero)
        // The web view got the keyboard: WebKit focuses no element by itself, so the page focuses its
        // primary input (Monaco) when nothing has focus (pane-focus-DESIGN.md P1).
        webView.onBecameFirstResponder = { [weak self] in self?.send(command: PageNativeOp.focusContent) }
        SystemScrollers.observe(self) { [weak self] _ in self?.applyTheme() } // theme carries data-scrollers
        observeStatusLook()
        wantsLayer = true
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // The page is transparent; WebKit's opaque backing would hide the window's backdrop.
        // macOS has no public switch, so this uses `_setDrawsBackground:` through KVC, checked first.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        // Web Inspector in every build (Inspect Element, Cmd-Opt-I).
        webView.isInspectable = true
        webView.navigationDelegate = self
        fileChooser = Self.openPanel.map { PageOpenPanel(openPanel: $0) }
        webView.uiDelegate = fileChooser
        webView.onUserEvent = { [weak self] in self?.noteTouch() }
        webView.pageAcceptsFirstMouse = { [weak self] in
            guard let self else { return false }
            return descriptor.acceptsFirstMouse || engineOptions.acceptsFirstMouse
        }
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        addSubview(webView)
        applyUIScale()
        observeUIScale()
        PageRegistry.add(self)
        let scripts = scripts
        router.send = { envelope in scripts.send(envelope) }
        router.sendWithDrop = { envelope, onDrop in scripts.send(envelope, onDrop: onDrop) }
        router.didClose = { [weak self] in
            scripts.reset()
            self?.popupHost?.hide()
        }
        router.titleBarDoubleClick = { [weak self] in self?.performTitleBarDoubleClick() }
        router.popup = { [weak self] op, params in self?.popup(op, params: params) ?? .object(["shown": .bool(false)]) }
        router.contextMenu = { [weak self] params in await self?.contextMenu(params) ?? .object(["picked": .null]) }
        router.userGestureEvent = { [weak self] in self?.recentUserGestureEvent() }
        #if DEBUG || CMUX_BENCH_HOOKS
        // Automation launches (no activation, a GUI host whose windows macOS reports occluded):
        // WebKit stops drawing an occluded window, so captures saw an empty page. DEBUG only;
        // users keep WebKit's occlusion throttling.
        if Self.rendersWhenCovered(ProcessInfo.processInfo.environment) { keepRenderingWhenCovered() }
        #endif
        // Console errors, uncaught errors and rejections go to the error journal (`cmux errors`).
        ConsoleErrorCapture(page: descriptor.id).install(in: webView.configuration.userContentController)
        PagePaintProbe.install(in: webView.configuration.userContentController) { [weak self] in
            self?.notePainted()
        }
        bridge.install { [weak self] message in
            await self?.receive(message)
        }
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        installDocumentStartTheme()
        guard load else { return }
        if engineDecision.engine == .cef, let hosting = chromium {
            startChromium(hosting: hosting)
        } else {
            #if DEBUG || CMUX_BENCH_HOOKS
            traceMark(.navigationStart)
            #endif
            webView.load(URLRequest(url: descriptor.url(route: route)))
        }
    }

    /// The current document painted its first frame (``PagePaintProbe``, either engine).
    func notePainted() {
        #if DEBUG || CMUX_BENCH_HOOKS
        traceMark(.pagePainted)
        #endif
        paintedUptime = ProcessInfo.processInfo.systemUptime
        let waiters = paintWaiters
        paintWaiters = []
        waiters.forEach { $0() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            uiScaleObservation?.cancel()
            statusLookObservation?.cancel()
        }
    }

    /// The theme carries the static status look (`data-status-indicators`, cx-sya4n): a change of
    /// the setting or of Reduce Motion pushes the theme again.
    private func observeStatusLook() {
        statusLookObservation = Task { [weak self] in
            for await _ in ObservationStream({ DesignSettings.shared.statusIndicator.animation }) {
                guard let self else { return }
                self.applyTheme()
            }
        }
        // Reduce Motion is not observable through Observation.
        reduceMotionObservers = [
            MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
                self?.applyTheme()
            },
            MainActorObservation(Motion.reduceMotionDidChange) { [weak self] in
                self?.applyTheme()
            },
            // The master motion switch, a category switch or the speed: `data-cmux-motion` follows.
            MainActorObservation(Motion.speedDidChange) { [weak self] in
                self?.applyTheme()
            },
        ]
    }

    private func observeUIScale() {
        uiScaleObservation = Task { [weak self] in
            for await _ in ObservationStream({ (DesignSettings.shared.uiScale, Typography.userScale) }) {
                guard let self else { return }
                self.applyUIScale()
            }
        }
    }

    /// Page zoom follows `uiScale` times this page's additional zoom; the chrome multiplier remains
    /// a separate `--cmux-interface-scale` token.
    func applyUIScale() {
        evaluateInPage(DesignSettings.shared.interfaceScaleScript(pageZoom: pageZoom))
        webView.pageZoom = pageZoom
        chromiumSession?.page.setZoom(pageZoom)
        if loaded { glassFeed.refresh() } // the zoom moves the art's rect in CSS px
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
        webView.frame = bounds
        if !nativeRects.isEmpty { applyNativeRects() } // the unflipped Chromium view's rects move with the height
        // Not while the claim is pending: a refused document reloads, and its paint would end the
        // pane's hold before the reloaded one drew (finishClaim runs the probe on acknowledgement).
        if repaintsAtNextLayout, !claimState.pending, window != nil, !bounds.isEmpty, !(superview is PageHostParking) {
            repaintsAtNextLayout = false
            evaluateInPage(PagePaintProbe.script)
        }
    }

    /// The fragment the host last asked the page to show (``open(route:)``); the page may move on
    /// by itself (its own links and history).
    public internal(set) var route: String?

    /// Shows `route` (the URL fragment) in the page.
    public func open(route: String) {
        let fragment = route.hasPrefix("#") ? route : "#" + route
        self.route = fragment
        guard loaded else {
            // Chromium mode before its page exists: the page loads `route` when it starts.
            if engineDecision.engine == .cef, chromiumSession == nil { return }
            loadDocument(descriptor.url(route: fragment))
            return
        }
        evaluateInPage("window.location.hash = \(JSONValue.string(fragment).compactText);")
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
        reloadPage()
    }

    /// Gives the page the keyboard focus.
    public func focusPage() {
        if let chromiumSession {
            chromiumSession.page.setFocused(true)
            return
        }
        window?.makeFirstResponder(webView)
    }

    /// When the current document painted its first frame (``PagePaintProbe``), in
    /// `ProcessInfo.systemUptime` seconds; nil until it has.
    public internal(set) var paintedUptime: TimeInterval?
    public var hasPainted: Bool { paintedUptime != nil }
    /// Callbacks for the current document's first frame (`whenPainted`).
    var paintWaiters: [() -> Void] = []
    /// A claimed spare painted while parked at its window's full size: it counts as painted again
    /// only once it drew at its own size (``claimDocument(documentAttributes:)``, ``layout()``).
    var repaintsAtNextLayout = false

    func receive(_ message: PageHostMessage) async -> Any? {
        guard PageHostTrust.isTrusted(message, page: descriptor) else {
            logger.error("page \(self.descriptor.id, privacy: .public) message from an untrusted frame refused: main=\(message.isMainFrame, privacy: .public) url=\(message.frameURL?.absoluteString ?? "-", privacy: .public)")
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
        setChromiumVisibility(true)
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        if !visible { chromiumSession?.questionKeys?.invalidate() }
        onVisibilityChanged?(visible)
        applyTheme()
        windowDidChangeChrome()
        if shouldFocusOnAttach, window != nil {
            shouldFocusOnAttach = false
            focusPage()
        }
    }

    /// Another tab took the pane: the page's popup ends.
    public override func viewDidHide() {
        super.viewDidHide()
        chromiumSession?.questionKeys?.invalidate()
        popupHost?.dismiss()
        setChromiumVisibility(false)
        onVisibilityChanged?(false)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        setChromiumVisibility(true)
        onVisibilityChanged?(visible)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        themeFollower.rebind()
        let visible = superview != nil && window != nil && !isHiddenOrHasHiddenAncestor
        if !visible { chromiumSession?.questionKeys?.invalidate() }
        onVisibilityChanged?(visible)
    }

    func applyTheme(force: Bool = false) {
        themeFollower.rebind()
        guard loaded else { return }
        let theme = currentTheme()
        if force || theme.payloadJSON != appliedTheme {
            appliedTheme = theme.payloadJSON
            evaluateInPage(theme.applyScript)
        }
        // After the theme, which sets `data-glass`; a forced push is a new document, which has no still yet.
        glassFeed.refresh(newDocument: force)
    }

    /// The page theme from this view's scope and ``themeSurface``: the surface's override (from
    /// `backgrounds`, the app's) replaces the page background; nil keeps the scope's own.
    /// Built in this view's scope (`performWithTheme`): whether the window is see-through here
    /// comes from that scope's picture and tint, not the app's. Built outside it, a workspace's
    /// picture over an opaque theme painted the page solid, a black chat over the wallpaper (#28867).
    func currentTheme(backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> WebTheme {
        performWithTheme {
            WebTheme(themeTokens, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                     surface: themeSurface ?? .internalPage, backgrounds: backgrounds)
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        switch PageNavigation.policy(for: url, page: descriptor, userClicked: action.navigationType == .linkActivated,
                                     mainFrame: action.targetFrame?.isMainFrame ?? true,
                                     targetFrameURL: action.targetFrame?.request.url,
                                     sourceFrameURL: action.sourceFrame.request.url, hook: onNavigate) {
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
