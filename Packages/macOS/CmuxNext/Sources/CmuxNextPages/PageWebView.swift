public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import Observation
import os
public import WebKit

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
    /// The WebKit view, for WebKit-only callers (focus, debug verbs). Engine-neutral code uses the
    /// router and the bridge instead.
    public var webKitView: WKWebView { webView }
    /// Whether the document can take typing yet (the dispatcher's type-ahead).
    public let inputReadiness: PageInputReadiness
    let bridge: any PageHostBridge
    var loaded = false
    var loadWaiters: [CheckedContinuation<Void, Never>] = []
    var shouldFocusOnAttach = false
    /// The last theme payload sent, so a redraw that changes nothing sends nothing.
    private var appliedTheme: String?
    private var uiScaleObservation: Task<Void, Never>?
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
    /// Decides navigations outside the page's origin (``PageNavigation/policy(for:page:userClicked:mainFrame:hook:)``).
    public var onNavigate: ((PageNavigation) -> PageNavigation.Policy)?
    /// The page's web content crashed. `reloading` is false once it crashed more often than
    /// ``PageCrashReloads`` allows: the page is not reloaded, and the host shows its notice (with a
    /// button that calls ``reloadAfterCrashes()``).
    public var onCrash: ((PageWebView, _ reloading: Bool) -> Void)?
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
    /// When a real key or mouse event last reached the page (`systemUptime`; page script cannot set
    /// it), the event behind `PageCallContext.userGesture`. A host that grants one action per
    /// gesture (a file page's "Open <path>?" sheet) records the value it used.
    public var lastUserEventUptime: TimeInterval? { (webView as? PageWKWebView)?.lastUserEventUptime }
    /// The crash clock (tests set it).
    var now: () -> Date = { Date() }
    var crashReloads = PageCrashReloads()
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
    nonisolated static func attributesScript(_ attributes: [String: String]) -> String? {
        let safe = attributes.filter { name, _ in !name.isEmpty && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } }
        guard !safe.isEmpty else { return nil }
        let lines = safe.keys.sorted().map { name in
            "document.documentElement.setAttribute(\(JSONValue.string("data-" + name).compactText), \(JSONValue.string(safe[name] ?? "").compactText));"
        }
        return lines.joined(separator: "\n")
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
    public convenience init?(descriptor: PageDescriptor, root: URL, routes: [PageRoute], route: String? = nil,
                             documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                             surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil) {
        guard Self.mayServe(descriptor, from: root) else { return nil }
        let host = Self.hostConfiguration(handler: PageSchemeHandler(page: descriptor, root: root,
                                                                       dynamicSource: dynamicResources),
                                          documentAttributes: documentAttributes, options: options)
        self.init(descriptor: descriptor, configuration: host.configuration, inputReadiness: host.inputReadiness,
                  routes: routes, route: route, options: options, surface: surface,
                  dynamicResources: dynamicResources, pooled: false, load: true)
    }

    init(descriptor: PageDescriptor, configuration: WKWebViewConfiguration,
         inputReadiness: PageInputReadiness, routes: [PageRoute], route: String?, options: PageEngineOptions,
         surface: SurfaceKind?, dynamicResources: (any PageDynamicResourceSource)?, pooled: Bool, load: Bool) {
        self.descriptor = descriptor
        engineOptions = options
        isPooled = pooled
        pooledOwner = nil
        themeSurface = surface
        self.dynamicResources = dynamicResources
        router = PageRouter(descriptor: descriptor, routes: routes)
        self.inputReadiness = inputReadiness
        webView = PageWKWebView(frame: .zero, configuration: configuration)
        inputReadiness.attach(webView)
        bridge = WebKitPageHostBridge(webView: webView)
        super.init(frame: .zero)
        SystemScrollers.observe(self) { [weak self] _ in self?.applyTheme() } // theme carries data-scrollers
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
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = self
        webView.onUserEvent = { [weak self] in self?.noteTouch() }
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        addSubview(webView)
        applyUIScale()
        observeUIScale()
        PageRegistry.add(self)
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
        router.titleBarDoubleClick = { [weak self] in self?.performTitleBarDoubleClick() }
        router.hasUserGesture = { [weak self] in (self?.webView as? PageWKWebView)?.hasRecentUserGesture() ?? false }
        #if DEBUG
        // Automation launches (no activation, a GUI host whose windows macOS reports occluded):
        // WebKit stops drawing an occluded window, so captures saw an empty page. DEBUG only;
        // users keep WebKit's occlusion throttling.
        if Self.rendersWhenCovered(ProcessInfo.processInfo.environment) { keepRenderingWhenCovered() }
        #endif
        PagePaintProbe.install(in: webView.configuration.userContentController) { [weak self] in
            self?.paintedUptime = ProcessInfo.processInfo.systemUptime
        }
        bridge.install { [weak self] message in
            await self?.receive(message)
        }
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        installDocumentStartTheme()
        if load { webView.load(URLRequest(url: descriptor.url(route: route))) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        uiScaleObservation?.cancel()
    }

    private func observeUIScale() {
        uiScaleObservation = Task { [weak self] in
            for await _ in Observations({ DesignSettings.shared.uiScale }) {
                guard let self else { return }
                self.applyUIScale()
            }
        }
    }

    /// Keeps first-party pages proportional to native chrome as the live
    /// interface scale changes.
    private func applyUIScale() {
        webView.pageZoom = Double(DesignSettings.shared.uiScale)
    }

    /// Marks a claimed pooled host as used by real input.
    func noteTouch() {
        if countsTouches { touched = true }
    }

    /// The window's title bar double-click action (System Settings > Desktop & Dock: zoom by
    /// default, minimize, or nothing), for a title bar the page draws (DESKTOP-FEEL).
    func performTitleBarDoubleClick() {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// The fragment the host last asked the page to show (``open(route:)``); the page may move on
    /// by itself (its own links and history).
    public internal(set) var route: String?

    /// Shows `route` (the URL fragment) in the page.
    public func open(route: String) {
        let fragment = route.hasPrefix("#") ? route : "#" + route
        self.route = fragment
        guard loaded else {
            webView.load(URLRequest(url: descriptor.url(route: fragment)))
            return
        }
        webView.evaluateJavaScript("window.location.hash = \(JSONValue.string(fragment).compactText);", completionHandler: nil)
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
        webView.reload()
    }

    /// Gives the page the keyboard focus.
    public func focusPage() {
        window?.makeFirstResponder(webView)
    }

    /// When the current document painted its first frame (``PagePaintProbe``), in
    /// `ProcessInfo.systemUptime` seconds; nil until it has.
    public private(set) var paintedUptime: TimeInterval?
    public var hasPainted: Bool { paintedUptime != nil }

    private func receive(_ message: PageHostMessage) async -> Any? {
        guard PageHostTrust.isTrusted(message, page: descriptor) else {
            logger.error("page \(self.descriptor.id, privacy: .public) message from an untrusted frame refused")
            return nil
        }
        guard let body = JSONValue(foundation: message.body) else { return nil }
        let reply = await router.handle(body)
        return reply.isNull ? nil : reply.foundationObject
    }

    // MARK: Theme

    // The page's colors follow this view's theme scope (room, workspace), resolved in the hooks
    // that run again on every theme change.
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = nil
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
        windowDidChangeChrome()
        if shouldFocusOnAttach, window != nil {
            shouldFocusOnAttach = false
            focusPage()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme(force: Bool = false) {
        guard loaded else { return }
        let theme = currentTheme()
        guard force || theme.payloadJSON != appliedTheme else { return }
        appliedTheme = theme.payloadJSON
        webView.evaluateJavaScript(theme.applyScript, completionHandler: nil)
    }

    /// The page theme from this view's scope and ``themeSurface``: the surface's override (from
    /// `backgrounds`, the app's) replaces the page background; nil keeps the scope's own.
    func currentTheme(backgrounds: SurfaceBackgrounds = ThemeScope.app.surfaceBackgrounds) -> WebTheme {
        WebTheme(themeTokens, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                 surface: themeSurface ?? .internalPage, backgrounds: backgrounds)
    }

    // MARK: WKNavigationDelegate

    // Completion-handler form: Xcode 26.6's compiler crashes emitting the ObjC
    // thunk for async delegate methods.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(policy(for: action))
    }

    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        let url = action.request.url
        switch PageNavigation.policy(for: url, page: descriptor, userClicked: action.navigationType == .linkActivated,
                                     mainFrame: action.targetFrame?.isMainFrame ?? true, hook: onNavigate) {
        case .allow:
            return .allow
        case .openExternal:
            if let url { onOpenExternal?(url) }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: the old one's subscriptions and host calls end with it, and it has not
        // painted yet.
        router.reset()
        _ = claimState.end()
        loaded = false
        paintedUptime = nil
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyUIScale()
        applyTheme(force: true)
        applyLiveDocumentAttributes()
        resumeLoadWaiters()
    }

}
