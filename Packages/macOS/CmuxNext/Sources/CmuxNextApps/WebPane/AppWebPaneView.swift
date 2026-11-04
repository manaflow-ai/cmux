public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups
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
    public private(set) var pane: AppWebPane
    let webView: WKWebView
    let bridge: AppWebPaneBridge
    private let schemeHandler: AppWebPaneSchemeHandler
    private weak var client: AppsClient?
    /// Follows eligibility even while cached outside a window: disabled code must stop there too.
    private var reloads: ReloadWatch?
    private var seenState: PaneState?
    /// Times the page reloaded for an app or file change (tests read it).
    private(set) var hotReloads = 0
    /// Called for each navigation the pane refused (tests wait on it).
    var onRefusedNavigation: (() -> Void)?
    /// Called once a document finishes loading (tests wait on invalidation).
    var onLoaded: (() -> Void)?
    /// The offline rule list is in place; nothing loads before it (``installOfflineRules()``).
    private(set) var offline = false
    /// WebKit allows no network host to this pane (`_allowedNetworkHosts`); without it nothing loads.
    let networkClosed: Bool
    /// Crash reloads since the page last loaded for another reason; a page that keeps
    /// crashing its process stays down after ``maxCrashReloads``.
    private var crashReloads = 0
    static let maxCrashReloads = 3

    public convenience init(pane: AppWebPane, client: AppsClient, work: BackgroundWork) {
        self.init(pane: pane, calls: client, work: work)
        self.client = client
        watchApp()
    }

    init(pane: AppWebPane, calls: any AppWebPaneCalls, work: BackgroundWork) {
        self.pane = pane
        bridge = AppWebPaneBridge(pane: pane, calls: calls)
        schemeHandler = AppWebPaneSchemeHandler(pane: pane, work: work)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: AppWebPane.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        // No WebRTC: ICE reaches any STUN or TURN host, which the content policy never sees.
        // WebKit has no public switch; skip the key if this WebKit does not answer its setter.
        // crash-allow: a fixed private setter name, only checked with responds(to:); no message is sent.
        if configuration.preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) {
            // crash-allow: guarded by responds(to:) on the private setter this KVC key resolves to; absent on older WebKit, skipped.
            configuration.preferences.setValue(false, forKey: "peerConnectionEnabled")
        }
        // No HTTP or WebSocket host at all: a clicked link preconnects to its host before the
        // navigation policy runs, and neither the content policy nor rule lists see that. An empty
        // allowed-host set refuses every network load and preconnect; the pane's own scheme is not
        // a network load. Private; a WebKit without it gets a blank pane, never an open one.
        // crash-allow: a fixed private setter name, only checked with responds(to:); no message is sent.
        networkClosed = configuration.responds(to: NSSelectorFromString("_setAllowedNetworkHosts:"))
        if networkClosed {
            // crash-allow: guarded by responds(to:) on the private setter this KVC key resolves to.
            configuration.setValue(NSSet(), forKey: "allowedNetworkHosts")
        }
        let content = configuration.userContentController
        content.addUserScript(AppWebPaneBridge.noPeerConnections)
        content.addUserScript(AppWebPaneBridge.script(appID: pane.appID))
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: AppWebPaneBridge.handlerName)
        // webview-allow: a sandboxed WebKit pane for user-written app code (non-persistent store, CSP floor, closed network hosts); a cmux page or browser tab engine would drop the sandbox
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
        installOfflineRules()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The renderer follows the same authoritative eligibility as the supervisor.
    private func watchApp() {
        guard let client else { return }
        let app = pane.appID
        let (first, later) = ObservationStream.current { [weak client] in
            PaneState(client: client, app: app)
        }
        // task-owner: this view, through ReloadWatch; cancelled when the view is released.
        // A cached view can still execute JavaScript, so it retains its eligibility watch.
        if first.pane != pane { filesChanged() }
        seenState = first
        reloads = ReloadWatch(task: Task { [weak self] in
            for await state in later {
                guard let self else { return }
                guard state != seenState else { continue }
                seenState = state
                filesChanged()
            }
        })
    }

    /// The app's files changed: load the page again from disk.
    func filesChanged() {
        hotReloads += 1
        crashReloads = 0
        webView.stopLoading()
        if let client {
            guard client.isListed, let app = client.app(pane.appID), app.isActive, app.available,
                  let bundle = client.bundleDirectory(for: app.id),
                  let latest = AppWebPane(manifest: app.manifest, bundle: bundle)
            else {
                revoke()
                return
            }
            pane = latest
            schemeHandler.pane = latest
            bridge.enabled = true
        }
        load()
    }

    /// Loads the entry page, once the offline rule list is in place.
    private func load() {
        // Offline-rule completion and crash callbacks may race the observation task.
        if let client, PaneState(client: client, app: pane.appID).pane == nil {
            revoke()
            return
        }
        guard offline, networkClosed, schemeHandler.pane != nil else { return }
        webView.load(URLRequest(url: pane.entryURL))
    }

    private func revoke() {
        webView.stopLoading()
        schemeHandler.pane = nil
        bridge.enabled = false
        webView.loadHTMLString("", baseURL: nil)
    }

    private struct PaneState: Equatable, Sendable {
        let revision: Int
        let pane: AppWebPane?

        init(client: AppsClient?, app: String) {
            revision = client?.fileRevisions[app] ?? 0
            if let client, client.isListed, let record = client.app(app), record.isActive, record.available,
               let bundle = client.bundleDirectory(for: app) {
                pane = AppWebPane(manifest: record.manifest, bundle: bundle)
            } else {
                pane = nil
            }
        }
    }

    /// Blocks every request outside the pane's own scheme (and the local `about:`, `data:` and
    /// `blob:`) before the first load. The content policy does not govern `<link rel=preconnect>`
    /// or `rel=dns-prefetch`, which reach any host (a lookup carries data in the name); WebKit
    /// checks content rule lists on those paths too. If the list does not compile, the pane
    /// stays blank: it never loads without it.
    private func installOfflineRules() {
        // task-owner: this view, weakly; one compile, then the first load. Fails closed.
        Task { [weak self] in
            let rules: WKContentRuleList?
            do {
                rules = try await WKContentRuleListStore.default()
                    .compileContentRuleList(forIdentifier: Self.offlineRulesID, encodedContentRuleList: Self.offlineRules)
            } catch {
                rules = nil
            }
            guard let self, let rules else { return }
            webView.configuration.userContentController.add(rules)
            offline = true
            load()
        }
    }

    static let offlineRulesID = "cmux-app-pane-offline-1"
    static let offlineRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^\(AppWebPane.scheme):"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Frames are refused by the content policy; the page stays on its own origin, and
        // with no UI delegate a new-window request opens nothing.
        // The host's invalidation document must replace the old page even though
        // loadHTMLString navigates to about:blank, outside the app's own origin.
        if schemeHandler.pane == nil, action.request.url?.absoluteString == "about:blank" { return .allow }
        guard pane.isOwn(action.request.url) else {
            onRefusedNavigation?()
            return .cancel
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onLoaded?()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        bridge.pageCommitted()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard crashReloads < Self.maxCrashReloads else { return }
        crashReloads += 1
        load()
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
