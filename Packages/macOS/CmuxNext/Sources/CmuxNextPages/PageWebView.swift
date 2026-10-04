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
    public let descriptor: PageDescriptor
    public let router: PageRouter
    let webView: WKWebView
    private let bridge: any PageHostBridge
    private var loaded = false
    /// The last theme payload sent, so a redraw that changes nothing sends nothing.
    private var appliedTheme: String?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")
    /// A navigation to any other origin (a link in the page): the host opens it in a browser tab.
    public var onOpenExternal: ((URL) -> Void)?

    public var pageID: String { descriptor.id }

    /// Nil when the page is missing from the resource bundle.
    public convenience init?(descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil) {
        guard let root = PageSchemeHandler.bundledRoot(for: descriptor) else { return nil }
        self.init(descriptor: descriptor, root: root, routes: routes, route: route)
    }

    /// `root` is the directory that holds the page's `index.html` (tests pass their own).
    public init(descriptor: PageDescriptor, root: URL, routes: [PageRoute], route: String? = nil) {
        self.descriptor = descriptor
        router = PageRouter(descriptor: descriptor, routes: routes)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PageSchemeHandler(page: descriptor, root: root), forURLScheme: PageDescriptor.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        webView = WKWebView(frame: .zero, configuration: configuration)
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
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        addSubview(webView)
        PageRegistry.add(self)
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
        bridge.install { [weak self] message in
            await self?.receive(message)
        }
        webView.load(URLRequest(url: descriptor.url(route: route)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Shows `route` (the URL fragment) in the page.
    public func open(route: String) {
        let fragment = route.hasPrefix("#") ? route : "#" + route
        guard loaded else {
            webView.load(URLRequest(url: descriptor.url(route: fragment)))
            return
        }
        webView.evaluateJavaScript("window.location.hash = \(JSONValue.string(fragment).compactText);", completionHandler: nil)
    }

    /// Sends a dispatcher command (`find`, with `text` for a find with a query) to the page.
    /// False when the page did not handle it.
    @discardableResult
    public func send(command: String, arguments: [String: JSONValue] = [:]) async -> Bool {
        var params = arguments
        params["command"] = .string(command)
        let reply = try? await router.callPage(PageNativeOp.pageCommand, params: .object(params))
        return reply?["handled"]?.boolValue ?? false
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
    }

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
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme(force: Bool = false) {
        guard loaded else { return }
        let theme = WebTheme(themeTokens, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        guard force || theme.payloadJSON != appliedTheme else { return }
        appliedTheme = theme.payloadJSON
        webView.evaluateJavaScript(theme.applyScript, completionHandler: nil)
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if descriptor.owns(url) { return .allow }
        if action.targetFrame?.isMainFrame ?? true, url.scheme != "about" { onOpenExternal?(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: the old one's subscriptions and host calls end with it.
        router.reset()
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyTheme(force: true)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        router.reset()
        webView.reload()
    }
}
