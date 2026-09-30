import AppKit
import CmuxAcpmux
import CmuxFoundation
import Observation
import SwiftUI
import WebKit

/// Hosts the optional TypeScript transcript renderer. Swift starts the daemon and
/// hands the page an authenticated endpoint; the page is the acpmux client.
struct AcpmuxChatWebRenderer: NSViewRepresentable {
    let panel: AgentSessionPanel
    let isFocused: Bool
    let backgroundColor: NSColor
    let theme: AgentSessionWebTheme
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> AcpmuxChatWebRendererCoordinator {
        AcpmuxChatWebRendererCoordinator(panel: panel, theme: theme)
    }

    func makeNSView(context: Context) -> NSView {
        panel.startChatIfNeeded()
        let host = AgentSessionWebHostView()
        host.wantsLayer = true
        host.layer?.backgroundColor = backgroundColor.cgColor
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? AgentSessionWebHostView else { return }
        let coordinator = context.coordinator
        coordinator.bind(theme: theme, isFocused: isFocused)
        let webView = coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.onPointerDown = onRequestPanelFocus
        webView.underPageBackgroundColor = backgroundColor
        webView.layer?.backgroundColor = backgroundColor.cgColor
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak coordinator] in coordinator?.loadShellIfNeeded() }
        coordinator.loadShellIfNeeded()
        if isFocused { coordinator.focus() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: AcpmuxChatWebRendererCoordinator) {
        guard let host = nsView as? AgentSessionWebHostView else { return }
        host.detachHostedWebViewIfOwned(coordinator.webView)
        coordinator.close()
    }
}

@MainActor
final class AcpmuxChatWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private let panel: AgentSessionPanel
    private let model: AcpmuxChatSessionModel
    private var theme: AgentSessionWebTheme
    var webView: AgentSessionWebView?
    private var loaded = false
    private var trustedURL: URL?
    private var isFocused = false
    private var lastFlingStats: [String: Any] = [:]
    private let customizationWatchers: [FileWatcher]
    private var customizationTasks: [Task<Void, Never>] = []

    init(panel: AgentSessionPanel, theme: AgentSessionWebTheme) {
        self.panel = panel
        self.model = panel.chatModel
        self.theme = theme
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/cmux/agent-pane")
        self.customizationWatchers = [
            FileWatcher(path: directory.path, throttle: .milliseconds(150)),
            FileWatcher(path: directory.appending(path: "theme.css").path, throttle: .milliseconds(150)),
            FileWatcher(path: directory.appending(path: "registry.js").path, throttle: .milliseconds(150)),
            FileWatcher(path: directory.appending(path: "layout.json").path, throttle: .milliseconds(150)),
        ]
        super.init()
#if DEBUG
        panel.onWebRendererDebugAction = { [weak self] action, params in
            self?.performDebugAction(action, params: params)
        }
#endif
        for watcher in customizationWatchers {
            customizationTasks.append(Task { [weak self] in
                for await _ in watcher.events {
                    self?.sendCustomization()
                }
            })
        }
        sendCustomization()
    }

    func bind(theme: AgentSessionWebTheme, isFocused: Bool) {
        self.theme = theme
        self.isFocused = isFocused
        if loaded { applyTheme() }
    }

    func ensureWebView(onPointerDown: @escaping () -> Void) -> AgentSessionWebView {
        if let webView {
            webView.onPointerDown = onPointerDown
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: AgentSessionBridgeContract.handlerName
        )
        let webView = AgentSessionWebView(frame: .zero, configuration: configuration)
        webView.onPointerDown = onPointerDown
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) { webView.isInspectable = false }
        self.webView = webView
        return webView
    }

    func loadShellIfNeeded() {
        guard !loaded, let webView, webView.window != nil,
              let resourceURL = Bundle.main.resourceURL else { return }
        let url = resourceURL.appendingPathComponent("acpmux-agent-session/index.html")
        trustedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        webView.loadFileURL(url, allowingReadAccessTo: resourceURL)
        loaded = true
    }

    func focus() { _ = webView?.window?.makeFirstResponder(webView) }

    func close() {
#if DEBUG
        panel.onWebRendererDebugAction = nil
#endif
        customizationTasks.forEach { $0.cancel() }
        customizationTasks.removeAll()
        for watcher in customizationWatchers {
            Task { await watcher.stop() }
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: AgentSessionBridgeContract.handlerName,
            contentWorld: .page
        )
        webView?.stopLoading()
        webView = nil
        loaded = false
    }

#if DEBUG
    private func performDebugAction(_ action: String, params: [String: Any]) -> [String: Any]? {
        switch action {
        case "seed_rows":
            let count = (params["count"] as? Int) ?? 5_000
            webView?.evaluateJavaScript("window.cmuxAcpmuxDebug?.seedRows(\(count)); true;") { _, _ in }
            return ["rows": count]
        case "fling":
            let seconds = (params["seconds"] as? Double) ?? 3
            let script = "window.cmuxAcpmuxDebug?.startFling(\(seconds)); true;"
            webView?.evaluateJavaScript(script) { _, _ in }
            return [:]
        case "fling_stats":
            webView?.evaluateJavaScript("window.cmuxAcpmuxDebug?.flingStats()") { [weak self] value, _ in
                Task { @MainActor in self?.lastFlingStats = value as? [String: Any] ?? [:] }
            }
            return lastFlingStats
        default:
            return nil
        }
    }
#endif

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              Self.isTrusted(message.frameInfo.request.url, expected: trustedURL) else {
            replyHandler(["ok": false, "error": ["code": "untrusted_frame"]], nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try Self.decodeRequest(message.body)
                let value = try await handle(request)
                replyHandler(["ok": true, "value": value], nil)
            } catch {
                replyHandler(["ok": false, "error": ["userMessage": error.localizedDescription]], nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyTheme()
        sendCustomization()
        if isFocused { focus() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if Self.isTrusted(url, expected: trustedURL) || Self.isTrustedFragment(url, expected: trustedURL) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    private func handle(_ request: Request) async throws -> Any {
        switch request.method {
        case "ready":
            let endpoint = try await model.webSocketEndpoint()
            applyTheme()
            sendCustomization()
            return Self.jsonObject(AcpmuxWebHostHandshake(endpoint: endpoint.endpoint, token: endpoint.token, sessionId: model.sessionId)) ?? [:]
        case "chat.persistSession":
            guard let sessionId = request.string("sessionId"), !sessionId.isEmpty else {
                throw NSError(domain: "AcpmuxWebBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing acpmux session id"])
            }
            model.rememberSession(sessionId: sessionId)
            return NSNull()
        default:
            throw NSError(domain: "AcpmuxWebBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported bridge request"])
        }
        return NSNull()
    }

    private func applyTheme() {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: theme.dictionary),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxAcpmuxBridge?.applyTheme(\(json));") { _, _ in }
    }

    private func sendCustomization() {
        guard let webView, loaded else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/cmux/agent-pane")
        let fileManager = FileManager.default
        let themeCSS = try? String(contentsOf: directory.appending(path: "theme.css"), encoding: .utf8)
        let registryJS = try? String(contentsOf: directory.appending(path: "registry.js"), encoding: .utf8)
        var layout: [String: Any] = [:]
        if let data = try? Data(contentsOf: directory.appending(path: "layout.json")),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            layout = decoded
        }
        let payload: [String: Any] = [
            "themeCSS": themeCSS as Any,
            "registryJS": registryJS as Any,
            "layout": layout,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxAcpmuxBridge?.applyCustomization(\(json));") { _, _ in }
        _ = fileManager
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object
    }

    private static func isTrusted(_ candidate: URL?, expected: URL?) -> Bool {
        guard let candidate, let expected, candidate.isFileURL, expected.isFileURL else { return false }
        return candidate.standardizedFileURL.resolvingSymlinksInPath() == expected.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isTrustedFragment(_ candidate: URL, expected: URL?) -> Bool {
        guard candidate.fragment != nil, var base = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let expected, var expectedBase = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        base.fragment = nil
        expectedBase.fragment = nil
        return isTrusted(base.url, expected: expectedBase.url)
    }

    private struct Request {
        let method: String
        let params: [String: Any]
        func string(_ key: String) -> String? { params[key] as? String }
    }

    private static func decodeRequest(_ body: Any) throws -> Request {
        guard let object = body as? [String: Any],
              let method = object["method"] as? String else {
            throw NSError(domain: "AcpmuxWebBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid bridge request"])
        }
        return Request(method: method, params: object["params"] as? [String: Any] ?? [:])
    }
}
