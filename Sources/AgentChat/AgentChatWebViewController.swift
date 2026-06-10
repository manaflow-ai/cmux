import AppKit
import WebKit

/// Hosts the webviews `/agent-chat` surface and bridges it to the local agent
/// conversation daemon.
///
/// JS -> Swift: the `agentChat` script message handler with `{id, method,
/// params}` bodies (`chat.init`, `chat.subscribe`), replied with `{ok, value}`
/// or `{ok: false, error}` (the same envelope the agent-session surface uses).
/// Swift -> JS: `window.cmuxAgentChatBridge.receive({type: "agent.event" |
/// "daemon.status", ...})` frames carrying the canonical conversation events
/// verbatim from the daemon (see webviews/src/agent-chat/protocol.ts).
@MainActor
final class AgentChatWebViewController: NSViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private static let handlerName = "agentChat"

    /// The resolved target session for this presentation.
    private var resolution: AgentChatTranscriptResolver.Resolution?

    private var webView: WKWebView?
    private var daemonClient: AgentDaemonClient?
    private var subscriptionId: String?

    /// Replaces the presented session; reloads the surface so the page state
    /// restarts from `chat.init` for the new target.
    func present(resolution: AgentChatTranscriptResolver.Resolution?) {
        self.resolution = resolution
        teardownDaemon()
        loadSurface()
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: Self.handlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        self.webView = webView
        view = webView
        loadSurface()
    }

    deinit {
        // The daemon child must never outlive its surface.
        daemonClient?.terminate()
    }

    private func loadSurface() {
        guard let webView, let resourceURL = Bundle.main.resourceURL else { return }
        let indexURL = resourceURL
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("agent-chat.html", isDirectory: false)
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceURL)
    }

    private func teardownDaemon() {
        daemonClient?.terminate()
        daemonClient = nil
        subscriptionId = nil
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(["ok": false, "error": ["code": "invalid_request"]], nil)
            return
        }
        switch method {
        case "chat.init":
            replyHandler(["ok": true, "value": initResultPayload()], nil)
        case "chat.subscribe":
            Task { [weak self] in
                guard let self else {
                    // The page awaits every reply; never leak the handler.
                    replyHandler(["ok": false, "error": ["code": "cancelled"]], nil)
                    return
                }
                do {
                    try await self.subscribe()
                    replyHandler(["ok": true, "value": NSNull()], nil)
                } catch {
                    replyHandler([
                        "ok": false,
                        "error": [
                            "code": "subscribe_failed",
                            "userMessage": error.localizedDescription,
                        ],
                    ], nil)
                }
            }
        default:
            replyHandler(["ok": false, "error": ["code": "unknown_method"]], nil)
        }
    }

    private func initResultPayload() -> [String: Any] {
        var payload: [String: Any] = [:]
        switch AgentDaemonBinaryLocator().locate() {
        case .found:
            payload["daemon_status"] = "ready"
        case .unavailable(let detail):
            payload["daemon_status"] = "unavailable"
            payload["daemon_detail"] = detail
        }
        if let session = sessionRefPayload() {
            payload["session"] = session
        }
        return payload
    }

    private func sessionRefPayload() -> [String: Any]? {
        guard let resolution, let transcriptURL = resolution.transcriptURL else { return nil }
        var session: [String: Any] = [
            "provider": resolution.provider.rawValue,
            "session_id": resolution.sessionId,
            "transcript_path": transcriptURL.path,
        ]
        if let cwd = resolution.workingDirectory {
            session["cwd"] = cwd
        }
        return session
    }

    private func subscribe() async throws {
        guard let resolution, let transcriptURL = resolution.transcriptURL else {
            throw AgentDaemonClient.DaemonError(
                code: "no_session",
                message: String(
                    localized: "agentChat.error.noTranscript",
                    defaultValue: "No transcript file was found for this agent session."
                )
            )
        }
        let binaryURL: URL
        switch AgentDaemonBinaryLocator().locate() {
        case .found(let url):
            binaryURL = url
        case .unavailable(let detail):
            throw AgentDaemonClient.DaemonError(code: "daemon_unavailable", message: detail)
        }

        teardownDaemon()
        let client = AgentDaemonClient(binaryURL: binaryURL)
        client.onEvent = { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.handleDaemonEvent(frame)
            }
        }
        client.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.pushToPage([
                    "type": "daemon.status",
                    "status": "unavailable",
                    "detail": "agent daemon exited (status \(status))",
                ])
            }
        }
        daemonClient = client
        try client.start()
        _ = try await client.request(method: "hello")
        let opened = try await client.request(method: "agent.session.open", params: [
            "provider": resolution.provider.rawValue,
            "transcript_path": transcriptURL.path,
        ])
        subscriptionId = opened["subscription_id"] as? String
    }

    private func handleDaemonEvent(_ frame: [String: Any]) {
        guard frame["event"] as? String == "agent.session.event" else { return }
        if let subscriptionId, let frameSubscription = frame["subscription_id"] as? String,
           frameSubscription != subscriptionId {
            return
        }
        guard let payload = frame["payload"] as? [String: Any] else { return }
        pushToPage(["type": "agent.event", "event": payload])
    }

    private func pushToPage(_ message: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.cmuxAgentChatBridge?.receive(\(json));") { _, _ in }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // The surface itself is file-served from the app bundle; anything else
        // (markdown links in chat content) opens in the default browser.
        if url.isFileURL {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
