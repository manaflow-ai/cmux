public import AppKit
import CmuxNextCompat
import WebKit

/// An app's custom pane: its own web page in a sandboxed web view
/// (custom-panes-DESIGN.md section 2).
///
/// - Files come only from the package's `runtime.web.root`, under the pane's own
///   origin (``AppWebPaneSchemeHandler``), with the host's content policy.
/// - Nothing persists: a non-persistent website data store per pane.
/// - The page navigates only within its own origin; links elsewhere, new windows,
///   frames and downloads go nowhere.
/// - Its one door out is `cmux.call` (``AppWebPaneBridge``), decided by the app
///   supervisor under the app's grant.
/// - When the app's files change on disk (a local app saved, an App Store bundle
///   replaced; ``AppsClient/fileRevisions``), the page reloads: hot reload.
@MainActor
public final class AppWebPaneView: NSView, WKNavigationDelegate {
    public let pane: AppWebPane
    let webView: WKWebView
    let bridge: AppWebPaneBridge
    private weak var client: AppsClient?
    private var reloads: Task<Void, Never>?
    /// Times the page reloaded for a file change (tests read it).
    private(set) var hotReloads = 0

    public convenience init(pane: AppWebPane, client: AppsClient) {
        self.init(pane: pane, calls: client)
        self.client = client
    }

    init(pane: AppWebPane, calls: any AppWebPaneCalls) {
        self.pane = pane
        bridge = AppWebPaneBridge(pane: pane, calls: calls)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(AppWebPaneSchemeHandler(pane: pane), forURLScheme: AppWebPane.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        let content = configuration.userContentController
        content.addUserScript(AppWebPaneBridge.script(appID: pane.appID))
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: AppWebPaneBridge.handlerName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        // The person building the pane opens Web Inspector on it.
        webView.isInspectable = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView.load(URLRequest(url: pane.entryURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            reloads?.cancel()
            reloads = nil
        } else if reloads == nil {
            watchFiles()
        }
    }

    /// Reloads the page each time the app's file count moves.
    private func watchFiles() {
        guard let client else { return }
        let app = pane.appID
        let (first, later) = ObservationStream.current { [weak client] in client?.fileRevisions[app] ?? 0 }
        // task-owner: this view; cancelled when it leaves its window
        reloads = Task { [weak self] in
            var seen = first
            for await revision in later {
                guard revision != seen else { continue }
                seen = revision
                self?.filesChanged()
            }
        }
    }

    /// The app's files changed: load the page again from disk.
    func filesChanged() {
        hotReloads += 1
        webView.load(URLRequest(url: pane.entryURL))
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Frames are refused by the content policy; the page stays on its own origin, and
        // with no UI delegate a new-window request opens nothing.
        pane.isOwn(action.request.url) ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        bridge.pageCommitted()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: pane.entryURL))
    }
}
