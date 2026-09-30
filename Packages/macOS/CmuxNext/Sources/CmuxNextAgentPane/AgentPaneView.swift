public import AppKit
import CmuxNextDesign
public import WebKit

/// Hosts the React agent pane (`Resources/agent-pane/index.html`, built by
/// `scripts/cmux-next/build-agent-pane-web.sh`) in a WKWebView. The page
/// connects to acpmux itself after the handshake; this view only answers
/// host requests, keeps the page on the bundled file, and applies the theme
/// of the scope it sits in (window, workspace), re-applied whenever that
/// scope repaints.
public final class AgentPaneView: NSView {
    public let model: AgentPaneModel
    public let webView: WKWebView
    /// Opens a link the user clicked in the transcript. Defaults to the
    /// system handler; the App can route it to a cmux browser tab.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    let pageURL: URL
    private let navigation = AgentPaneNavigation()

    /// Nil when the bundled page is missing (a broken build).
    public init?(model: AgentPaneModel) {
        guard let page = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-pane") else { return nil }
        self.model = model
        pageURL = page
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.addScriptMessageHandler(
            AgentPaneBridge(view: self), contentWorld: .page, name: AgentPaneRequest.handlerName
        )
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        navigation.view = self
        webView.navigationDelegate = navigation
        addSubview(webView)
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Stops the page (and its WebSocket) for good; call when the tab closes.
    public func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: AgentPaneRequest.handlerName, contentWorld: .page)
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        removeFromSuperview()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    /// Pushes this view's scope tokens to the page (and to the area WebKit
    /// shows before the page paints).
    func applyTheme() {
        let tokens = themeTokens
        webView.underPageBackgroundColor = tokens.contentBackground.nsColor
        guard let script = AgentPaneTheme.script(tokens) else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
