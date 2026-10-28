public import AppKit
import CmuxNextCompat
public import WebKit

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
    /// The hot reload watch; dropping it (the view gone, or out of its window) ends it.
    private var reloads: ReloadWatch?
    /// The app's file revision the page last loaded (nil before the first watch).
    private var seenRevision: Int?
    /// Times the page reloaded for a file change (tests read it).
    private(set) var hotReloads = 0
    /// Called for each navigation the pane refused (tests wait on it).
    var onRefusedNavigation: (() -> Void)?

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
        // No network the content policy cannot see: WebRTC (ICE reaches any STUN or TURN host)
        // and DNS prefetch (a lookup carries data in the name). WebKit has no public switch for
        // either; skip a key this WebKit does not answer rather than raise.
        for (key, setter) in [("peerConnectionEnabled", "_setPeerConnectionEnabled:"),
                              ("DNSPrefetchingEnabled", "_setDNSPrefetchingEnabled:")]
            // crash-allow: a fixed private setter name, only checked with responds(to:); no message is sent.
            where configuration.preferences.responds(to: NSSelectorFromString(setter)) {
            // crash-allow: guarded by responds(to:) on the private setter this KVC key resolves to; absent on older WebKit, skipped.
            configuration.preferences.setValue(false, forKey: key)
        }
        let content = configuration.userContentController
        content.addUserScript(AppWebPaneBridge.noPeerConnections)
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
        // task-owner: this view, through ReloadWatch; cancelled when the view leaves its window or goes
        // Files saved while the pane was out of its window reload it on the way back.
        if let seenRevision, seenRevision != first { filesChanged() }
        seenRevision = first
        reloads = ReloadWatch(task: Task { [weak self] in
            for await revision in later {
                guard let self else { return }
                guard revision != seenRevision else { continue }
                seenRevision = revision
                filesChanged()
            }
        })
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
        guard pane.isOwn(action.request.url) else {
            onRefusedNavigation?()
            return .cancel
        }
        return .allow
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

/// Owns the hot reload task and cancels it when released, so it never outlives its view.
private nonisolated final class ReloadWatch: Sendable {
    let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        task.cancel()
    }
}
