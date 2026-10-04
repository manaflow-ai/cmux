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
/// `cmux-page://<id>/` from the bundled page, with the shared web theme (`WebTheme`) and the
/// engine-neutral bridge (``PageHostBridge`` + ``PageRouter``).
///
/// Absorbs the Settings lead's `SettingsWebPageView` (branch feat-cmux-next-settings-react):
/// transparency, the scheme-handler origin, the main-frame and origin check, the debug state and
/// snapshot.
@MainActor
public final class PageWebView: NSView, ThemeResponsive, PageSurface, WKNavigationDelegate {
    public let descriptor: PageDescriptor
    public let router: PageRouter
    let webView: WKWebView
    private let bridge: any PageHostBridge
    private weak var scope: ThemeScope?
    private var loaded = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")
    /// A navigation to any other origin (a link in the page): the host opens it in a browser tab.
    public var onOpenExternal: ((URL) -> Void)?

    public var pageID: String { descriptor.id }

    /// Nil when the page is missing from the resource bundle.
    public convenience init?(descriptor: PageDescriptor, routes: [PageRoute], scope: ThemeScope, route: String? = nil) {
        guard let root = PageSchemeHandler.bundledRoot(for: descriptor) else { return nil }
        self.init(descriptor: descriptor, root: root, routes: routes, scope: scope, route: route)
    }

    /// `root` is the directory that holds the page's `index.html` (tests pass their own).
    public init(descriptor: PageDescriptor, root: URL, routes: [PageRoute], scope: ThemeScope, route: String? = nil) {
        self.descriptor = descriptor
        router = PageRouter(descriptor: descriptor, routes: routes)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PageSchemeHandler(page: descriptor, root: root), forURLScheme: PageDescriptor.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        webView = WKWebView(frame: .zero, configuration: configuration)
        bridge = WebKitPageHostBridge(webView: webView)
        self.scope = scope
        super.init(frame: .zero)
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
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
        bridge.install { [weak self] message in
            await self?.receive(message)
        }
        scope.addResponder(self)
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

    /// Sends a dispatcher command (`find`) to the page. False when the page did not handle it.
    @discardableResult
    public func send(command: String) async -> Bool {
        let reply = try? await router.callPage(PageNativeOp.pageCommand, params: ["command": .string(command)])
        return reply?["handled"]?.boolValue ?? false
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

    public func themeDidChange() {
        guard loaded, let scope else { return }
        let theme = WebTheme(scope.tokens, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
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
        themeDidChange()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        router.reset()
        webView.reload()
    }
}
