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
#if DEBUG
        cmuxDebugLog(
            "agentChat.web.present session=\(resolution?.sessionId.prefix(8) ?? "nil") " +
            "transcriptFound=\(resolution?.transcriptURL != nil ? 1 : 0)"
        )
#endif
        self.resolution = resolution
        teardownDaemon()
        loadSurface()
    }

    /// Terminates the daemon child without reloading the page; called when
    /// the hosting panel closes for good.
    func teardownForClose() {
#if DEBUG
        cmuxDebugLog("agentChat.web.teardownForClose")
#endif
        resolution = nil
        teardownDaemon()
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: Self.handlerName
        )
#if DEBUG
        // Surface page-level JS failures in the debug log so a blank surface
        // is diagnosable from the tagged log sink.
        let errorRelay = """
        window.addEventListener('error', (e) => {
          try { window.webkit.messageHandlers.agentChat.postMessage({method:'page.error', params:{message:String(e.message||''), source:String(e.filename||''), line:(e.lineno||0)}}); } catch (_) {}
        });
        window.addEventListener('unhandledrejection', (e) => {
          try { window.webkit.messageHandlers.agentChat.postMessage({method:'page.error', params:{message:String((e.reason && e.reason.message) || e.reason || 'unhandledrejection')}}); } catch (_) {}
        });
        """
        configuration.userContentController.addUserScript(WKUserScript(
            source: errorRelay,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
#endif
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
#if DEBUG
            cmuxDebugLog("agentChat.web.bridge method=chat.init")
#endif
            replyHandler(["ok": true, "value": initResultPayload()], nil)
        case "chat.subscribe":
#if DEBUG
            cmuxDebugLog("agentChat.web.bridge method=chat.subscribe")
#endif
            Task { [weak self] in
                guard let self else {
                    // The page awaits every reply; never leak the handler.
                    replyHandler(["ok": false, "error": ["code": "cancelled"]], nil)
                    return
                }
                do {
                    try await self.subscribe()
#if DEBUG
                    cmuxDebugLog("agentChat.web.subscribe result=ok")
#endif
                    replyHandler(["ok": true, "value": NSNull()], nil)
                } catch {
#if DEBUG
                    cmuxDebugLog("agentChat.web.subscribe result=error detail=\(error.localizedDescription)")
#endif
                    replyHandler([
                        "ok": false,
                        "error": [
                            "code": "subscribe_failed",
                            "userMessage": error.localizedDescription,
                        ],
                    ], nil)
                }
            }
        case "page.error":
#if DEBUG
            let params = body["params"] as? [String: Any]
            cmuxDebugLog(
                "agentChat.web.pageError message=\(params?["message"] as? String ?? "?") " +
                "source=\(params?["source"] as? String ?? "?") line=\(params?["line"] as? Int ?? 0)"
            )
#endif
            replyHandler(["ok": true, "value": NSNull()], nil)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WKWebView does not execute `<script type="module" src>` under
        // file:// (CORS-opaque origin), but dynamic import() from injected
        // script works. Kick the entry module manually; main.mjs routes by
        // data-cmux-webview-kind and mounts the surface. Follow-up: serve
        // this surface over the diff-viewer custom scheme (the serving
        // spine), which makes the script tag work natively.
        webView.evaluateJavaScript(
            "if (document.getElementById('root') && document.getElementById('root').childElementCount === 0) { import('./main.mjs'); }"
        ) { _, _ in }
#if DEBUG
        cmuxDebugLog("agentChat.web.didFinish")
        webView.evaluateJavaScript(
            "document.readyState + '|' + document.title + '|' + (window.cmuxAgentChatBridge ? 'bridge' : 'nobridge')"
        ) { value, error in
            cmuxDebugLog(
                "agentChat.web.pageState value=\(value as? String ?? "nil") " +
                "error=\(error?.localizedDescription ?? "none")"
            )
        }
        webView.callAsyncJavaScript(
            """
            const fetched = performance.getEntriesByType('resource').map((r) => r.name.split('/').pop()).join(',');
            try {
              const surface = await import('./chunks/agentChatSurface.mjs');
              let mount = 'skipped';
              const root = document.getElementById('root');
              if (root && root.childElementCount === 0) {
                try {
                  surface.mountAgentChatSurface(root);
                  mount = 'manual-ok';
                } catch (e) {
                  mount = 'manual-fail:' + ((e && e.message) ? e.message : String(e));
                }
              }
              return 'import-ok rootChildren=' + (root ? root.childElementCount : -1) +
                ' mount=' + mount + ' fetched=' + fetched;
            } catch (e) {
              return 'import-fail message=' + ((e && e.message) ? e.message : String(e)) + ' fetched=' + fetched;
            }
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success(let value):
                cmuxDebugLog("agentChat.web.importProbe value=\(value as? String ?? "nil")")
            case .failure(let error):
                cmuxDebugLog("agentChat.web.importProbe error=\(error.localizedDescription)")
            }
        }
#endif
    }

#if DEBUG
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        cmuxDebugLog("agentChat.web.didFailProvisional error=\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        cmuxDebugLog("agentChat.web.didFail error=\(error.localizedDescription)")
    }
#endif

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
