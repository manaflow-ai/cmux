import AppKit
import SwiftUI
import WebKit

struct AgentSessionWebRenderer: NSViewRepresentable {
    let panel: AgentSessionPanel
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.initialProviderID,
            workingDirectory: panel.workingDirectory
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = context.coordinator.webView {
            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            webView.onPointerDown = onRequestPanelFocus
            applyBackground(to: webView)
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator,
            contentWorld: .page,
            name: AgentSessionBridgeContract.handlerName
        )
        let webView = AgentSessionWebView(frame: .zero, configuration: configuration)
        webView.onPointerDown = onRequestPanelFocus
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        applyBackground(to: webView)
        context.coordinator.webView = webView
        context.coordinator.loadShell()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.bind(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.initialProviderID,
            workingDirectory: panel.workingDirectory
        )
        (nsView as? AgentSessionWebView)?.onPointerDown = onRequestPanelFocus
        applyBackground(to: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if let retainedWebView = coordinator.webView, retainedWebView === nsView {
            return
        }
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: AgentSessionBridgeContract.handlerName,
            contentWorld: .page
        )
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        (nsView as? AgentSessionWebView)?.onPointerDown = nil
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }
}

enum AgentSessionBridgeContract {
    static let handlerName = "agentSession"
}

@MainActor
final class AgentSessionWebView: WKWebView {
    var onPointerDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}

@MainActor
final class AgentSessionWebRendererSession {
    private let ownedCoordinator = AgentSessionWebRenderer.Coordinator()

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID,
        workingDirectory: String?
    ) -> AgentSessionWebRenderer.Coordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            initialProviderID: initialProviderID,
            workingDirectory: workingDirectory
        )
        return ownedCoordinator
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func close() {
        ownedCoordinator.close()
    }
}

extension AgentSessionWebRenderer {
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        var webView: AgentSessionWebView?
        private var panelId = UUID()
        private var workspaceId = UUID()
        private var rendererKind: AgentSessionRendererKind = .react
        private var initialProviderID: AgentSessionProviderID = .codex
        private var workingDirectory: String?
        private var processStore = AgentSessionProcessStore()

        func bind(
            panelId: UUID,
            workspaceId: UUID,
            rendererKind: AgentSessionRendererKind,
            initialProviderID: AgentSessionProviderID,
            workingDirectory: String?
        ) {
            self.panelId = panelId
            self.workspaceId = workspaceId
            self.rendererKind = rendererKind
            self.initialProviderID = initialProviderID
            self.workingDirectory = workingDirectory
            processStore.eventSink = { [weak self] event in
                self?.sendEvent(event)
            }
        }

        func loadShell() {
            guard let resourceDirectoryURL = Bundle.main.resourceURL?
                .appendingPathComponent(rendererKind.resourceDirectoryName, isDirectory: true) else {
                return
            }
            let indexURL = resourceDirectoryURL.appendingPathComponent("index.html", isDirectory: false)
            if let html = try? String(contentsOf: indexURL, encoding: .utf8) {
                webView?.loadHTMLString(html, baseURL: resourceDirectoryURL)
            } else {
                webView?.loadFileURL(indexURL, allowingReadAccessTo: resourceDirectoryURL)
            }
        }

        func focus() {
            guard let webView else { return }
            _ = webView.window?.makeFirstResponder(webView)
        }

        func close() {
            processStore.closeAll()
            if let webView {
                webView.stopLoading()
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: AgentSessionBridgeContract.handlerName,
                    contentWorld: .page
                )
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.onPointerDown = nil
            }
            webView = nil
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            Task { @MainActor in
                do {
                    let request = try AgentSessionBridgeRequest(body: message.body)
                    let reply = try await self.handle(request)
                    replyHandler(["ok": true, "value": reply], nil)
                } catch let error as AgentExecutableResolverError {
                    replyHandler(["ok": false, "error": ["message": error.message]], nil)
                } catch {
                    replyHandler(["ok": false, "error": ["message": error.localizedDescription]], nil)
                }
            }
        }

        private func handle(_ request: AgentSessionBridgeRequest) async throws -> Any {
            switch request.method {
            case "app.context":
                var context: [String: Any] = [
                    "panelId": panelId.uuidString,
                    "workspaceId": workspaceId.uuidString,
                    "renderer": rendererKind.rawValue,
                    "initialProviderId": initialProviderID.rawValue,
                    "copy": [
                        "start": String(localized: "agentSession.web.start", defaultValue: "Start"),
                        "stop": String(localized: "agentSession.web.stop", defaultValue: "Stop"),
                        "send": String(localized: "agentSession.web.send", defaultValue: "Send"),
                        "promptPlaceholder": String(
                            localized: "agentSession.web.promptPlaceholder",
                            defaultValue: "Ask anything"
                        )
                    ]
                ]
                if let workingDirectory {
                    context["workingDirectory"] = workingDirectory
                }
                return context
            case "provider.list":
                return AgentSessionProviderID.allCases.map { provider in
                    [
                        "id": provider.rawValue,
                        "displayName": provider.displayName,
                        "executableName": provider.executableName,
                        "transportKind": provider.transportKind,
                        "arguments": provider.launchArguments
                    ] as [String: Any]
                }
            case "provider.start":
                let provider = try request.providerID()
                let resolver = AgentExecutableResolver()
                let plan = try resolver.resolve(provider)
                let session = try processStore.start(
                    plan: plan,
                    workingDirectory: request.string("workingDirectory") ?? workingDirectory
                )
                return [
                    "sessionId": session.sessionId,
                    "providerId": provider.rawValue,
                    "executablePath": plan.executableURL.path,
                    "arguments": plan.arguments
                ] as [String: Any]
            case "provider.writeLine":
                try processStore.writeLine(
                    sessionId: request.requiredString("sessionId"),
                    text: request.requiredString("text")
                )
                return ["sent": true]
            case "provider.stop":
                try processStore.stop(sessionId: request.requiredString("sessionId"))
                return ["stopped": true]
            case "http.request":
                return try await AgentSessionHTTPBridge.perform(request: request)
            default:
                throw AgentSessionBridgeError.unsupportedMethod(request.method)
            }
        }

        private func sendEvent(_ event: [String: Any]) {
            guard let webView,
                  let data = try? JSONSerialization.data(withJSONObject: event),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("window.cmuxAgentBridge?.receive(\(json));") { _, error in
#if DEBUG
                if let error {
                    cmuxDebugLog("agentSession.bridge.event.failed error=\(error.localizedDescription)")
                }
#else
                _ = error
#endif
            }
        }
    }
}

private struct AgentSessionBridgeRequest {
    let id: String
    let method: String
    let params: [String: Any]

    init(body: Any) throws {
        guard let dictionary = body as? [String: Any],
              let id = dictionary["id"] as? String,
              let method = dictionary["method"] as? String else {
            throw AgentSessionBridgeError.invalidRequest
        }
        self.id = id
        self.method = method
        self.params = dictionary["params"] as? [String: Any] ?? [:]
    }

    func string(_ key: String) -> String? {
        let trimmed = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw AgentSessionBridgeError.missingParameter(key)
        }
        return value
    }

    func providerID() throws -> AgentSessionProviderID {
        let rawValue = try requiredString("providerId")
        guard let provider = AgentSessionProviderID(rawValue: rawValue) else {
            throw AgentSessionBridgeError.invalidProvider(rawValue)
        }
        return provider
    }
}

private enum AgentSessionBridgeError: LocalizedError {
    case invalidRequest
    case invalidProvider(String)
    case missingParameter(String)
    case unsupportedMethod(String)
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return String(localized: "agentSession.bridge.error.invalidRequest", defaultValue: "Invalid bridge request.")
        case .invalidProvider(let provider):
            let format = String(
                localized: "agentSession.bridge.error.invalidProvider",
                defaultValue: "Unknown provider: %@"
            )
            return String(format: format, provider)
        case .missingParameter(let parameter):
            let format = String(
                localized: "agentSession.bridge.error.missingParameter",
                defaultValue: "Missing bridge parameter: %@"
            )
            return String(format: format, parameter)
        case .unsupportedMethod(let method):
            let format = String(
                localized: "agentSession.bridge.error.unsupportedMethod",
                defaultValue: "Unsupported bridge method: %@"
            )
            return String(format: format, method)
        case .sessionNotFound(let sessionId):
            let format = String(
                localized: "agentSession.bridge.error.sessionNotFound",
                defaultValue: "Agent session was not found: %@"
            )
            return String(format: format, sessionId)
        }
    }
}

@MainActor
private final class AgentSessionProcessStore {
    struct StartedSession {
        let sessionId: String
    }

    var eventSink: (([String: Any]) -> Void)?
    private var sessions: [String: RunningSession] = [:]

    func start(plan: AgentSessionLaunchPlan, workingDirectory: String?) throws -> StartedSession {
        let sessionId = UUID().uuidString
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let running = RunningSession(
            sessionId: sessionId,
            providerID: plan.provider,
            process: process,
            stdin: stdin
        )
        sessions[sessionId] = running

        installReadHandler(stdout.fileHandleForReading, sessionId: sessionId, stream: "stdout")
        installReadHandler(stderr.fileHandleForReading, sessionId: sessionId, stream: "stderr")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.eventSink?([
                    "type": "provider.exit",
                    "sessionId": sessionId,
                    "providerId": plan.provider.rawValue,
                    "status": process.terminationStatus
                ])
                self?.sessions.removeValue(forKey: sessionId)
            }
        }

        do {
            try process.run()
        } catch {
            sessions.removeValue(forKey: sessionId)
            throw error
        }

        eventSink?([
            "type": "provider.started",
            "sessionId": sessionId,
            "providerId": plan.provider.rawValue,
            "executablePath": plan.executableURL.path,
            "arguments": plan.arguments
        ])
        return StartedSession(sessionId: sessionId)
    }

    func writeLine(sessionId: String, text: String) throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        session.stdin.fileHandleForWriting.write(data)
    }

    func stop(sessionId: String) throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        session.process.terminate()
    }

    func closeAll() {
        for session in sessions.values {
            session.process.terminate()
        }
        sessions.removeAll()
    }

    private func installReadHandler(_ fileHandle: FileHandle, sessionId: String, stream: String) {
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                self.eventSink?([
                    "type": "provider.output",
                    "sessionId": sessionId,
                    "providerId": session.providerID.rawValue,
                    "stream": stream,
                    "text": text
                ])
            }
        }
    }

    private final class RunningSession {
        let sessionId: String
        let providerID: AgentSessionProviderID
        let process: Process
        let stdin: Pipe

        init(
            sessionId: String,
            providerID: AgentSessionProviderID,
            process: Process,
            stdin: Pipe
        ) {
            self.sessionId = sessionId
            self.providerID = providerID
            self.process = process
            self.stdin = stdin
        }
    }
}

private enum AgentSessionHTTPBridge {
    static func perform(request: AgentSessionBridgeRequest) async throws -> [String: Any] {
        guard let url = URL(string: try request.requiredString("url")) else {
            throw AgentSessionBridgeError.missingParameter("url")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.string("method") ?? "GET"
        if let headers = request.params["headers"] as? [String: String] {
            for (key, value) in headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = request.params["body"] as? String {
            urlRequest.httpBody = body.data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        let headerFields = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = "\(entry.value)"
        } ?? [:]
        return [
            "status": httpResponse?.statusCode ?? 0,
            "headers": headerFields,
            "bodyText": String(data: data, encoding: .utf8) ?? ""
        ]
    }
}
