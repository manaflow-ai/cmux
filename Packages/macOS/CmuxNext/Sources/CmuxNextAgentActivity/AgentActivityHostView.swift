public import AppKit
public import WebKit
import CmuxNextDesign

/// Hosts the Activity renderer in a web view while keeping socket and native
/// operation ownership in ``AgentActivityModel`` and its injected source.
public final class AgentActivityHostView: NSView {
    public let model: AgentActivityModel
    public let webView: WKWebView
    private let source: any AgentActivitySource
    /// The theme payload the loaded page last got, so a repaint with the same colors is free.
    private var appliedTheme: String?
    /// Coalesces bursts of model updates into one web-view state transfer per main-queue turn.
    /// Activity events can arrive as a batch, and serializing the full projection for every
    /// element makes the main actor and WebKit do redundant work while the page is catching up.
    private var statePushScheduled = false
    /// The wallpaper still the page's glass lenses (`cmuxTheme.backdrop`), pushed after each theme.
    private lazy var glassFeed = GlassBackdropFeed(host: webView, zoom: { [webView] in webView.pageZoom * webView.magnification }) { [weak self] in
        self?.webView.evaluateJavaScript($0, completionHandler: nil)
    }
    /// Pushes the theme again on every repaint of this view's scope (the glass mode included).
    private lazy var themeFollower = ThemeFollower(self) { [weak self] in self?.applyTheme() }

    /// Makes an Activity web view for a model and its native data source.
    public init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bridge = AgentActivityBridge(model: model, source: source)
        model.layout = AgentActivityTunables.layout.value
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: AgentActivityBridge.handlerName)
        // The shared web theme (`window.cmuxTheme`, `--cmux-*`), as on every cmux page: the
        // bootstrap, then the app's colors for the first frame; the view's scope follows on load.
        WebTheme.installUserScripts(on: configuration.userContentController)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.theme(.app).applyScript, injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        // webview-allow: fallback only; the app shows the Activity page on the page host (CmuxNextApp AgentActivityPageTab)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init(frame: .zero)
        webView.navigationDelegate = bridge
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) { webView.setValue(false, forKey: "drawsBackground") }
        // Web Inspector in every build (Inspect Element, Cmd-Opt-I).
        webView.isInspectable = true
        bridge.view = self
        model.onChange = { [weak self] in self?.scheduleStatePush() }
        addSubview(webView)
        if let page = Self.bundledPage { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
    }

    /// Compatibility initializer for prototype snapshot callers.
    public convenience init(model: AgentActivityModel, layoutOverride: AgentActivityLayout? = nil) {
        if let layoutOverride { model.layout = layoutOverride }
        self.init(model: model, source: AgentActivityMockSource())
    }

    /// The bundled Activity page.
    public static var bundledPage: URL? { Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-activity") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() { super.layout(); webView.frame = bounds }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    /// Gives the page this view's scope colors when they changed; `reload` after a navigation,
    /// whose new document has only the document-start colors.
    fileprivate func applyTheme(reload: Bool = false) {
        themeFollower.rebind()
        if reload { appliedTheme = nil }
        // In this view's scope: see-through or opaque follows its workspace's picture (#28867).
        let theme = performWithTheme { Self.theme(themeScope) }
        if theme.payloadJSON != appliedTheme {
            appliedTheme = theme.payloadJSON
            webView.evaluateJavaScript(theme.applyScript, completionHandler: nil)
        }
        // After the theme, which sets `data-glass`; a reload is a new document with no still yet.
        glassFeed.refresh(newDocument: reload)
    }

    private static func theme(_ scope: ThemeScope) -> WebTheme {
        WebTheme(scope.tokens, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                 surface: .internalPage)
    }

    private func scheduleStatePush() {
        guard !statePushScheduled else { return }
        statePushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            statePushScheduled = false
            pushState()
        }
    }

    private func pushState() {
        guard webView.url != nil else { return }
        let state = AgentActivityRequests(model: model, source: source).state()
        guard JSONSerialization.isValidJSONObject(state), let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxActivityReceive && window.cmuxActivityReceive(\(json));", completionHandler: nil)
    }
}

private final class AgentActivityBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let handlerName = "agentActivity"
    weak var view: AgentActivityHostView?
    let model: AgentActivityModel
    let source: any AgentActivitySource

    init(model: AgentActivityModel, source: any AgentActivitySource) { self.model = model; self.source = source }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        view?.applyTheme(reload: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return (["ok": false, "error": ["userMessage": "Invalid Activity request"]], nil)
        }
        return await reply(to: method, params: body["params"] as? [String: Any] ?? [:])
    }

    @MainActor
    private func reply(to method: String, params: [String: Any]) async -> (Any?, String?) {
        (await AgentActivityRequests(model: model, source: source).reply(to: method, params: params), nil)
    }
}
