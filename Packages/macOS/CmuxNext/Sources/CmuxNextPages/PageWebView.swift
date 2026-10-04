public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
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
    /// The page the view serves now: its ops (``router``), commands and accessibility id. A pooled
    /// host's claim or retarget changes it (``retarget(descriptor:routes:dynamicResources:)``).
    public internal(set) var descriptor: PageDescriptor
    /// The document's own page (its origin): the trust check reads it. The same as ``descriptor``
    /// except while a shell page is claimed (then ``PageDescriptor/shell``).
    public internal(set) var servedDescriptor: PageDescriptor
    public let router: PageRouter
    let webView: PageWKWebView
    /// The WebKit view, for WebKit-only callers (focus, debug verbs). Engine-neutral code uses the
    /// router and the bridge instead.
    public var webKitView: WKWebView { webView }
    let bridge: any PageHostBridge
    var loaded = false
    var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// The last theme payload sent, so a redraw that changes nothing sends nothing.
    private var appliedTheme: String?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")
    /// Answers the page's dynamic prefixes (``PageDescriptor/dynamicPrefixes``); the scheme
    /// handler holds it weakly, so the view keeps it alive.
    var dynamicResources: (any PageDynamicResourceSource)?
    /// A pooled host (``PageHostPool``): one scheme handler serves every first-party page, so the
    /// view may be retargeted to another page.
    public let isPooled: Bool
    /// The pooled host was used: a user event reached its web view, or its page sent an op (any
    /// message but a reply to a host call). Owned by Swift; it never goes back to false.
    public internal(set) var touched = false
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
    public var themeSurface: SurfaceKind? {
        didSet { if themeSurface != oldValue { applyTheme() } }
    }
    /// The crash clock (tests set it).
    var now: () -> Date = { Date() }
    private var crashReloads = PageCrashReloads()

    public var pageID: String { descriptor.id }

    /// Nil when the page is missing from the resource bundle and no root is registered for it
    /// (``PageID/registerBundledRoot(_:for:)``).
    public convenience init?(descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                             documentAttributes: [String: String] = [:], surface: SurfaceKind? = nil,
                             dynamicResources: (any PageDynamicResourceSource)? = nil) {
        guard let root = Self.servedRoot(for: descriptor) else { return nil }
        self.init(descriptor: descriptor, root: root, routes: routes, route: route, documentAttributes: documentAttributes,
                  surface: surface, dynamicResources: dynamicResources)
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
        let handler = PageSchemeHandler(page: descriptor, root: root, dynamicSource: dynamicResources)
        self.init(descriptor: descriptor, handler: handler, routes: routes, route: route,
                  documentAttributes: documentAttributes, options: options, surface: surface,
                  dynamicResources: dynamicResources, pooled: false)
    }

    /// A pooled host (``PageHostPool``) that shows `served` (default the page shell): one scheme
    /// handler for every first-party page (``PageServedHosts``), its own non-persistent website
    /// data store, so no host sees another host's storage. Nil when `served` has no root.
    public convenience init?(pooledHost served: PageDescriptor = .shell, routes: [PageRoute] = [],
                             options: PageEngineOptions = .standard) {
        guard PageID.isFirstParty(served.id), Self.servedRoot(for: served) != nil else { return nil }
        let owner = PageServedOwner()
        let handler = PageSchemeHandler { host in owner.view?.servedHost(host) }
        self.init(descriptor: served, handler: handler, routes: routes, route: nil, documentAttributes: [:],
                  options: options, surface: nil, dynamicResources: nil, pooled: true)
        owner.view = self
    }

    private init(descriptor: PageDescriptor, handler: PageSchemeHandler, routes: [PageRoute], route: String?,
                 documentAttributes: [String: String], options: PageEngineOptions, surface: SurfaceKind?,
                 dynamicResources: (any PageDynamicResourceSource)?, pooled: Bool) {
        self.descriptor = descriptor
        servedDescriptor = descriptor
        isPooled = pooled
        themeSurface = surface
        self.dynamicResources = dynamicResources
        router = PageRouter(descriptor: descriptor, routes: routes)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = PageProcessPool.forNewView
        if options.fullFrameRate {
            configuration.preferences.setWebKitFeature(PageEngineOptions.near60FPSFeature, enabled: false)
        }
        configuration.setURLSchemeHandler(handler, forURLScheme: PageDescriptor.scheme)
        Self.installUserScripts(configuration.userContentController, documentAttributes: documentAttributes)
        webView = PageWKWebView(frame: .zero, configuration: configuration)
        bridge = WebKitPageHostBridge(webView: webView)
        super.init(frame: .zero)
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
        webView.onUserEvent = { [weak self] in self?.touched = true }
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        addSubview(webView)
        PageRegistry.add(self)
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
        router.titleBarDoubleClick = { [weak self] in self?.performTitleBarDoubleClick() }
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
        webView.load(URLRequest(url: descriptor.url(route: route)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
    /// by itself (its own links and history). A pooled host's claim or retarget sets it anew.
    public internal(set) var route: String?

    /// Shows `route` (the URL fragment) in the page.
    public func open(route: String) {
        let fragment = route.hasPrefix("#") ? route : "#" + route
        self.route = fragment
        guard loaded else {
            webView.load(URLRequest(url: servedDescriptor.url(route: fragment)))
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

    /// The tab closed: cancels subscriptions and stops the bridge.
    public func close() {
        router.close()
        bridge.uninstall()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PagePaintProbe.handlerName, contentWorld: .page)
        resumeLoadWaiters()
    }

    /// When the current document painted its first frame (``PagePaintProbe``), or the shell
    /// mounted its claimed page, in `ProcessInfo.systemUptime` seconds; nil until it has.
    public internal(set) var paintedUptime: TimeInterval?
    public var hasPainted: Bool { paintedUptime != nil }
    /// Called when the page reports its first frame (stub: not called yet).
    public var onPaint: (() -> Void)?

    func receive(_ message: PageHostMessage) async -> Any? {
        // Trust checks the document's origin: while a shell page is claimed, that is the shell.
        guard PageHostTrust.isTrusted(message, page: servedDescriptor) else {
            logger.error("page \(self.servedDescriptor.id, privacy: .public) message from an untrusted frame refused")
            return nil
        }
        guard let body = JSONValue(foundation: message.body) else { return nil }
        // Any op of the page marks the host used; replies to the host's own calls do not.
        if let type = body["t"]?.stringValue, type != "ok", type != "err" { touched = true }
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

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        switch PageNavigation.policy(for: url, page: servedDescriptor, userClicked: action.navigationType == .linkActivated,
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
        paintedUptime = nil
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyTheme(force: true)
        resumeLoadWaiters()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        logger.error("page \(self.servedDescriptor.id, privacy: .public) failed to load")
        resumeLoadWaiters()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        logger.error("page \(self.servedDescriptor.id, privacy: .public) failed to load")
        resumeLoadWaiters()
    }

    func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        router.reset()
        let reloading = crashReloads.shouldReload(at: now())
        if reloading {
            webView.reload()
        } else {
            logger.error("page \(self.descriptor.id, privacy: .public) keeps crashing; not reloaded")
        }
        onCrash?(self, reloading)
    }

    /// Reloads a page that stopped reloading after crashes, and forgets those crashes (the crash
    /// notice's Reload button).
    public func reloadAfterCrashes() {
        crashReloads = PageCrashReloads()
        webView.reload()
    }
}
