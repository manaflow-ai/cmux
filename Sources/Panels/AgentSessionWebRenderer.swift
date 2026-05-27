import AppKit
import SwiftUI
import WebKit

struct AgentSessionWebRenderer: NSViewRepresentable {
    let panel: AgentSessionPanel
    let isFocused: Bool
    let backgroundColor: NSColor
    let theme: AgentSessionWebTheme
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.initialProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
    }

    func makeNSView(context: Context) -> AgentSessionWebView {
        let webView = context.coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.onPointerDown = onRequestPanelFocus
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        applyBackground(to: webView)
        applyAppearance(to: webView)
        context.coordinator.loadShellIfNeeded()
        if isFocused {
            context.coordinator.focus()
        }
        return webView
    }

    func updateNSView(_ nsView: AgentSessionWebView, context: Context) {
        context.coordinator.bind(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.initialProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        nsView.onPointerDown = onRequestPanelFocus
        nsView.navigationDelegate = context.coordinator
        nsView.uiDelegate = context.coordinator
        applyBackground(to: nsView)
        applyAppearance(to: nsView)
        context.coordinator.loadShellIfNeeded()
        context.coordinator.flushVisiblePaintIfReady()
        if isFocused {
            context.coordinator.focus()
        }
    }

    static func dismantleNSView(_ nsView: AgentSessionWebView, coordinator: Coordinator) {
        if let retainedWebView = coordinator.webView, nsView === retainedWebView {
            return
        }
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.onPointerDown = nil
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
    }

    private func applyAppearance(to webView: WKWebView) {
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }

}

struct AgentSessionWebTheme: Equatable {
    let isDark: Bool
    let pageBackground: String
    let surfaceBackground: String
    let surfaceElevatedBackground: String
    let inputBackground: String
    let border: String
    let borderStrong: String
    let text: String
    let mutedText: String
    let softText: String
    let accent: String
    let accentSoft: String
    let danger: String
    let shadow: String

    var dictionary: [String: Any] {
        [
            "isDark": isDark,
            "pageBackground": pageBackground,
            "surfaceBackground": surfaceBackground,
            "surfaceElevatedBackground": surfaceElevatedBackground,
            "inputBackground": inputBackground,
            "border": border,
            "borderStrong": borderStrong,
            "text": text,
            "mutedText": mutedText,
            "softText": softText,
            "accent": accent,
            "accentSoft": accentSoft,
            "danger": danger,
            "shadow": shadow
        ]
    }

    static func resolve(appearance: PanelAppearance) -> AgentSessionWebTheme {
        let base = appearance.backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlay: NSColor = isDark ? .white : .black
        let inverseOverlay: NSColor = isDark ? .black : .white
        let contentBackground = appearance.contentBackgroundColor
        let transparentContent = contentBackground.alphaComponent < 0.001
        let baseSurfaceAlpha: CGFloat = appearance.drawsContentBackground ? 0.72 : 0.34
        let elevatedSurfaceAlpha: CGFloat = appearance.drawsContentBackground ? 0.84 : 0.48
        let inputAlpha: CGFloat = appearance.drawsContentBackground ? 0.60 : 0.36
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.62 : 1.34,
            of: overlay
        )
        let borderStrong = base.markdownThemeOverlay(
            targetContrast: isDark ? 2.12 : 1.64,
            of: overlay
        )
        let surface = base
            .blended(withFraction: isDark ? 0.05 : 0.03, of: overlay)?
            .withAlphaComponent(baseSurfaceAlpha)
            ?? base.withAlphaComponent(baseSurfaceAlpha)
        let surfaceElevated = base
            .blended(withFraction: isDark ? 0.08 : 0.05, of: overlay)?
            .withAlphaComponent(elevatedSurfaceAlpha)
            ?? base.withAlphaComponent(elevatedSurfaceAlpha)
        let input = base
            .blended(withFraction: isDark ? 0.18 : 0.10, of: inverseOverlay)?
            .withAlphaComponent(inputAlpha)
            ?? base.withAlphaComponent(inputAlpha)
        let foreground = appearance.foregroundColor
        let accent = cmuxAccentNSColor()
        let danger = (NSColor(hex: isDark ? "#FF8D7E" : "#B3261E") ?? .systemRed)
        return AgentSessionWebTheme(
            isDark: isDark,
            pageBackground: transparentContent ? "transparent" : contentBackground.markdownCSSColor,
            surfaceBackground: surface.markdownCSSColor,
            surfaceElevatedBackground: surfaceElevated.markdownCSSColor,
            inputBackground: input.markdownCSSColor,
            border: border.withAlphaComponent(border.alphaComponent * 0.72).markdownCSSColor,
            borderStrong: borderStrong.markdownCSSColor,
            text: foreground.markdownCSSColor,
            mutedText: foreground.withAlphaComponent(0.58).markdownCSSColor,
            softText: foreground.withAlphaComponent(0.78).markdownCSSColor,
            accent: accent.markdownCSSColor,
            accentSoft: accent.withAlphaComponent(isDark ? 0.20 : 0.16).markdownCSSColor,
            danger: danger.markdownCSSColor,
            shadow: isDark ? "rgba(0, 0, 0, 0.20)" : "rgba(0, 0, 0, 0.10)"
        )
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
        workingDirectory: String?,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> AgentSessionWebRenderer.Coordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            initialProviderID: initialProviderID,
            workingDirectory: workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        return ownedCoordinator
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func unfocus() {
        ownedCoordinator.unfocus()
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
        private var theme: AgentSessionWebTheme = .resolve(
            appearance: .fromConfig(GhosttyConfig.load())
        )
        private var loadedRendererKind: AgentSessionRendererKind?
        private var hasFinishedNavigation = false
        private var hasCompletedVisiblePaintFlush = false
        private var isPanelFocused = false
        private var processStore = AgentSessionProcessStore()

        func bind(
            panelId: UUID,
            workspaceId: UUID,
            rendererKind: AgentSessionRendererKind,
            initialProviderID: AgentSessionProviderID,
            workingDirectory: String?,
            theme: AgentSessionWebTheme,
            isFocused: Bool
        ) {
            self.panelId = panelId
            self.workspaceId = workspaceId
            if self.rendererKind != rendererKind {
                loadedRendererKind = nil
                hasFinishedNavigation = false
                hasCompletedVisiblePaintFlush = false
            }
            self.rendererKind = rendererKind
            self.initialProviderID = initialProviderID
            self.workingDirectory = workingDirectory
            isPanelFocused = isFocused
            let themeChanged = self.theme != theme
            self.theme = theme
            if themeChanged {
                applyThemeToLoadedPage()
            }
            processStore.eventSink = { [weak self] event in
                self?.sendEvent(event)
            }
        }

        func ensureWebView(onPointerDown: @escaping () -> Void) -> AgentSessionWebView {
            if let webView {
                webView.onPointerDown = onPointerDown
                return webView
            }

            let configuration = WKWebViewConfiguration()
            configuration.suppressesIncrementalRendering = false
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
            webView.navigationDelegate = self
            webView.uiDelegate = self
            if #available(macOS 13.3, *) {
#if DEBUG
                webView.isInspectable = true
#else
                webView.isInspectable = false
#endif
            }
            self.webView = webView
            return webView
        }

        func loadShellIfNeeded() {
            guard loadedRendererKind != rendererKind else {
                return
            }
            guard let resourceDirectoryURL = Bundle.main.resourceURL?
                .appendingPathComponent(rendererKind.resourceDirectoryName, isDirectory: true) else {
                return
            }
            let indexURL = resourceDirectoryURL.appendingPathComponent("index.html", isDirectory: false)
#if DEBUG
            cmuxDebugLog(
                "agentSession.web.load renderer=\(rendererKind.rawValue) " +
                "index=\(indexURL.path)"
            )
#endif
            webView?.loadFileURL(indexURL, allowingReadAccessTo: resourceDirectoryURL)
            loadedRendererKind = rendererKind
            hasFinishedNavigation = false
            hasCompletedVisiblePaintFlush = false
        }

        func focus() {
            guard let webView else { return }
            _ = webView.window?.makeFirstResponder(webView)
        }

        func unfocus() {
            guard let webView,
                  let window = webView.window,
                  Self.responderChainContains(window.firstResponder, target: webView) else {
                return
            }
            window.makeFirstResponder(nil)
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
            loadedRendererKind = nil
            hasFinishedNavigation = false
            hasCompletedVisiblePaintFlush = false
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
                    replyHandler(["ok": false, "error": ["userMessage": error.message]], nil)
                } catch let error as AgentSessionBridgeError {
                    replyHandler(["ok": false, "error": ["userMessage": error.localizedDescription]], nil)
                } catch {
                    replyHandler(["ok": false, "error": [:]], nil)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
            cmuxDebugLog("agentSession.web.didFinish renderer=\(rendererKind.rawValue)")
#endif
            hasFinishedNavigation = true
            applyThemeToLoadedPage()
            if isPanelFocused {
                focus()
            }
            flushInitialPaint(for: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
#if DEBUG
            cmuxDebugLog(
                "agentSession.web.didFail renderer=\(rendererKind.rawValue) " +
                "error=\(error.localizedDescription)"
            )
#endif
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
#if DEBUG
            cmuxDebugLog(
                "agentSession.web.didFailProvisional renderer=\(rendererKind.rawValue) " +
                "error=\(error.localizedDescription)"
            )
#endif
        }

        func flushVisiblePaintIfReady() {
            guard hasFinishedNavigation,
                  !hasCompletedVisiblePaintFlush,
                  let webView,
                  webView.window != nil,
                  !webView.bounds.isEmpty else {
                return
            }
            flushInitialPaint(for: webView) { [weak self] in
                self?.hasCompletedVisiblePaintFlush = true
            }
        }

        private func flushInitialPaint(for webView: WKWebView, completion: (() -> Void)? = nil) {
            // Retained WKWebViews can finish loading before Bonsplit reattaches them
            // to a visible host. Reading layout after navigation forces WebKit to
            // commit the first page layer once the view is back in the pane.
            let script = """
            (() => {
              const root = document.getElementById('root');
              const shell = document.querySelector('.agent-shell');
              const rootRect = root ? root.getBoundingClientRect() : null;
              void (document.body && document.body.innerText);
              void (rootRect && rootRect.width);
              void (shell && getComputedStyle(shell).backgroundColor);
              return true;
            })()
            """
            webView.evaluateJavaScript(script) { _, _ in
                webView.setNeedsDisplay(webView.bounds)
                completion?()
            }
        }

        private func applyThemeToLoadedPage() {
            guard let webView,
                  let data = try? JSONSerialization.data(withJSONObject: theme.dictionary),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("window.cmuxAgentBridge?.applyTheme(\(json));") { _, error in
#if DEBUG
                if let error {
                    cmuxDebugLog("agentSession.web.theme.failed error=\(error.localizedDescription)")
                }
#else
                _ = error
#endif
            }
            sendEvent([
                "type": "app.theme",
                "theme": theme.dictionary
            ])
        }

        private func handle(_ request: AgentSessionBridgeRequest) async throws -> Any {
            switch request.method {
            case "app.context":
                var context: [String: Any] = [
                    "panelId": panelId.uuidString,
                    "workspaceId": workspaceId.uuidString,
                    "renderer": rendererKind.rawValue,
                    "initialProviderId": initialProviderID.rawValue,
                    "theme": theme.dictionary,
                    "copy": [
                        "start": String(localized: "agentSession.web.start", defaultValue: "Start"),
                        "stop": String(localized: "agentSession.web.stop", defaultValue: "Stop"),
                        "send": String(localized: "agentSession.web.send", defaultValue: "Send"),
                        "provider": String(localized: "agentSession.web.provider", defaultValue: "Provider"),
                        "rateLimits": String(localized: "agentSession.web.rateLimits", defaultValue: "Rate limits"),
                        "voiceInput": String(localized: "agentSession.web.voiceInput", defaultValue: "Voice input"),
                        "promptPlaceholder": String(
                            localized: "agentSession.web.promptPlaceholder",
                            defaultValue: "Ask anything"
                        ),
                        "attachFile": String(
                            localized: "agentSession.web.attachFile",
                            defaultValue: "Attach file"
                        ),
                        "browseWeb": String(localized: "agentSession.web.browseWeb", defaultValue: "Browse web"),
                        "autoContext": String(localized: "agentSession.web.autoContext", defaultValue: "Context"),
                        "tools": String(localized: "agentSession.web.tools", defaultValue: "Tools"),
                        "mentionMenuTitle": String(
                            localized: "agentSession.web.mentionMenuTitle",
                            defaultValue: "Mention"
                        ),
                        "mentionCurrentWorkspace": String(
                            localized: "agentSession.web.mentionCurrentWorkspace",
                            defaultValue: "Current workspace"
                        ),
                        "skillMenuTitle": String(
                            localized: "agentSession.web.skillMenuTitle",
                            defaultValue: "Skills"
                        ),
                        "skillPlan": String(localized: "agentSession.web.skillPlan", defaultValue: "Plan"),
                        "skillCodeReview": String(
                            localized: "agentSession.web.skillCodeReview",
                            defaultValue: "Code review"
                        ),
                        "skillResearch": String(
                            localized: "agentSession.web.skillResearch",
                            defaultValue: "Research"
                        ),
                        "loadingStatus": String(localized: "agentSession.web.status.loading", defaultValue: "Loading"),
                        "idleStatus": String(localized: "agentSession.web.status.idle", defaultValue: "Idle"),
                        "startingStatus": String(localized: "agentSession.web.status.starting", defaultValue: "Starting"),
                        "runningStatus": String(localized: "agentSession.web.status.running", defaultValue: "Running"),
                        "stoppingStatus": String(localized: "agentSession.web.status.stopping", defaultValue: "Stopping"),
                        "failedStatus": String(localized: "agentSession.web.status.failed", defaultValue: "Failed"),
                        "rendererReadyFormat": String(
                            localized: "agentSession.web.log.rendererReadyFormat",
                            defaultValue: "%@ ready"
                        ),
                        "stopped": String(localized: "agentSession.web.log.stopped", defaultValue: "Stopped"),
                        "sentCharsFormat": String(
                            localized: "agentSession.web.log.sentCharsFormat",
                            defaultValue: "Sent %d chars"
                        ),
                        "providerStarted": String(
                            localized: "agentSession.web.log.providerStarted",
                            defaultValue: "Provider started"
                        ),
                        "providerExitedFormat": String(
                            localized: "agentSession.web.log.providerExitedFormat",
                            defaultValue: "Provider exited %d"
                        ),
                        "requestFailed": String(
                            localized: "agentSession.web.error.requestFailed",
                            defaultValue: "Native bridge request failed."
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
                        "arguments": provider.launchArguments,
                        "autoStart": provider.shouldAutoStartSession
                    ] as [String: Any]
                }
            case "provider.start":
                let provider = try request.providerID()
                let resolver = AgentExecutableResolver(
                    configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
                )
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
                try await processStore.writeLine(
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

        private static func responderChainContains(_ responder: NSResponder?, target: NSResponder) -> Bool {
            var current = responder
            while let item = current {
                if item === target {
                    return true
                }
                current = item.nextResponder
            }
            return false
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
    case sessionAlreadyRunning
    case providerNotReady(String)
    case unsupportedTransport(String)

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
        case .sessionAlreadyRunning:
            return String(
                localized: "agentSession.bridge.error.sessionAlreadyRunning",
                defaultValue: "An agent session is already running."
            )
        case .providerNotReady(let provider):
            let format = String(
                localized: "agentSession.bridge.error.providerNotReady",
                defaultValue: "%@ is not ready yet."
            )
            return String(format: format, provider)
        case .unsupportedTransport(let transport):
            let format = String(
                localized: "agentSession.bridge.error.unsupportedTransport",
                defaultValue: "Agent transport is not supported: %@"
            )
            return String(format: format, transport)
        }
    }
}

@MainActor
final class CodexAppServerSession {
    typealias DataWriter = (Data) throws -> Void
    typealias OutputSink = (_ stream: String, _ text: String) -> Void

    private let workingDirectory: String?
    private let writeData: DataWriter
    private let outputSink: OutputSink
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var didInitialize = false
    private var threadStartRequestID: Int?
    private var threadID: String?
    private var queuedInputs: [String] = []
    private var stdoutBuffer = ""

    init(
        workingDirectory: String?,
        writeData: @escaping DataWriter,
        outputSink: @escaping OutputSink
    ) {
        self.workingDirectory = workingDirectory
        self.writeData = writeData
        self.outputSink = outputSink
    }

    func start() throws {
        initializeRequestID = try sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "cmux",
                    "title": "cmux",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false
                ]
            ]
        )
    }

    func submit(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let threadID else {
            queuedInputs.append(trimmed)
            if didInitialize {
                try startThreadIfNeeded()
            }
            return
        }
        try sendTurnStart(threadID: threadID, text: trimmed)
    }

    func consumeStdout(_ text: String) {
        stdoutBuffer.append(text)
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(...newlineRange.lowerBound)
            if !line.isEmpty {
                handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            outputSink("stderr", String(localized: "agentSession.codex.error.invalidJSON", defaultValue: "Codex app-server response was not valid JSON."))
            return
        }

        if let method = object["method"] as? String,
           object["id"] != nil {
            handleServerRequest(object, method: method)
            return
        }

        if let method = object["method"] as? String {
            handleNotification(method: method, params: object["params"] as? [String: Any])
            return
        }

        guard let id = requestID(from: object["id"]) else { return }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(localized: "agentSession.codex.error.rpcFailed", defaultValue: "Codex app-server request failed.")
            outputSink("stderr", message)
            return
        }
        handleResponse(id: id, result: object["result"] as? [String: Any])
    }

    private func handleResponse(id: Int, result: [String: Any]?) {
        if id == initializeRequestID {
            didInitialize = true
            do {
                try sendNotification(method: "initialized")
                try startThreadIfNeeded()
            } catch {
                outputSink("stderr", error.localizedDescription)
            }
            return
        }

        if id == threadStartRequestID,
           let thread = result?["thread"] as? [String: Any],
           let id = thread["id"] as? String {
            threadID = id
            threadStartRequestID = nil
            drainQueuedInputs()
            return
        }
    }

    private func handleNotification(method: String, params: [String: Any]?) {
        switch method {
        case "thread/started":
            if threadID == nil,
               let thread = params?["thread"] as? [String: Any],
               let id = thread["id"] as? String {
                threadID = id
                drainQueuedInputs()
            }
        case "item/agentMessage/delta":
            if let delta = params?["delta"] as? String {
                outputSink("stdout", delta)
            }
        case "error":
            let error = params?["error"] as? [String: Any]
            outputSink("stderr", error?["message"] as? String ?? String(localized: "agentSession.codex.error.rpcFailed", defaultValue: "Codex app-server request failed."))
        case "warning", "guardianWarning", "configWarning", "deprecationNotice":
            outputSink("stderr", codexMessage(from: params) ?? method)
        default:
            break
        }
    }

    private func handleServerRequest(_ object: [String: Any], method: String) {
        guard let id = object["id"] else { return }
        let result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval":
            result = ["decision": "decline"]
        case "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval":
            result = ["decision": "denied"]
        default:
            do {
                try sendErrorResponse(
                    id: id,
                    code: -32601,
                    message: String(
                        format: String(
                            localized: "agentSession.codex.error.unsupportedServerRequest",
                            defaultValue: "Request from Codex app-server is not supported: %@"
                        ),
                        method
                    )
                )
            } catch {
                outputSink("stderr", error.localizedDescription)
            }
            return
        }

        do {
            try sendJSONObject(["id": id, "result": result])
        } catch {
            outputSink("stderr", error.localizedDescription)
        }
    }

    private func drainQueuedInputs() {
        guard let threadID else { return }
        let inputs = queuedInputs
        queuedInputs.removeAll()
        for input in inputs {
            do {
                try sendTurnStart(threadID: threadID, text: input)
            } catch {
                outputSink("stderr", error.localizedDescription)
            }
        }
    }

    private func startThreadIfNeeded() throws {
        guard threadID == nil, threadStartRequestID == nil else { return }
        var params: [String: Any] = [
            "serviceName": "cmux",
            "threadSource": "user"
        ]
        if let workingDirectory {
            params["cwd"] = workingDirectory
        }
        threadStartRequestID = try sendRequest(method: "thread/start", params: params)
    }

    private func sendTurnStart(threadID: String, text: String) throws {
        _ = try sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [
                    [
                        "type": "text",
                        "text": text,
                        "text_elements": []
                    ]
                ]
            ]
        )
    }

    @discardableResult
    private func sendRequest(method: String, params: Any) throws -> Int {
        let id = nextRequestID
        nextRequestID += 1
        try sendJSONObject([
            "id": id,
            "method": method,
            "params": params
        ])
        return id
    }

    private func sendNotification(method: String) throws {
        try sendJSONObject(["method": method])
    }

    private func sendErrorResponse(id: Any, code: Int, message: String) throws {
        try sendJSONObject([
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func sendJSONObject(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try writeData(data)
    }

    private func requestID(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func codexMessage(from params: [String: Any]?) -> String? {
        if let message = params?["message"] as? String {
            return message
        }
        if let warning = params?["warning"] as? String {
            return warning
        }
        if let error = params?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
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
        guard sessions.isEmpty else {
            throw AgentSessionBridgeError.sessionAlreadyRunning
        }
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
            executablePath: plan.executableURL.path,
            arguments: plan.arguments,
            workingDirectory: workingDirectory,
            process: process,
            stdin: stdin
        )
        if plan.provider == .codex {
            running.codexAppServerSession = CodexAppServerSession(
                workingDirectory: workingDirectory,
                writeData: { data in
                    try stdin.fileHandleForWriting.write(contentsOf: data)
                },
                outputSink: { [weak self] stream, text in
                    self?.emitOutput(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        stream: stream,
                        text: text
                    )
                }
            )
        }
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
            try running.codexAppServerSession?.start()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            sessions.removeValue(forKey: sessionId)
            throw error
        }

        if plan.provider != .opencode {
            emitStarted(session: running)
        }
        return StartedSession(sessionId: sessionId)
    }

    func writeLine(sessionId: String, text: String) async throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }

        switch session.providerID {
        case .codex:
            guard let codexAppServerSession = session.codexAppServerSession else {
                throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
            }
            try codexAppServerSession.submit(text)
        case .claude:
            try writeClaudeStreamJSON(text, to: session.stdin)
        case .opencode:
            try await postOpenCodePrompt(text, session: session)
        }
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
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    for text in session.flushBufferedOutput(stream: stream) {
                        self.handleOutputLine(text, session: session, stream: stream)
                    }
                    return
                }
                for text in session.appendOutputData(data, stream: stream) {
                    self.handleOutputLine(text, session: session, stream: stream)
                }
            }
        }
    }

    private func handleOutputLine(_ text: String, session: RunningSession, stream: String) {
        if session.providerID == .opencode,
           session.openCodeBaseURL == nil,
           let baseURL = openCodeServerURL(from: text) {
            session.openCodeBaseURL = baseURL
            createOpenCodeSession(session)
        }

        if stream == "stdout",
           let codexAppServerSession = session.codexAppServerSession {
            codexAppServerSession.consumeStdout(text)
            return
        }

        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: stream,
            text: text
        )
    }

    private func openCodeServerURL(from text: String) -> URL? {
        let marker = "opencode server listening on "
        guard let range = text.range(of: marker) else { return nil }
        let rawURL = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        return rawURL.flatMap(URL.init(string:))
    }

    private func createOpenCodeSession(_ session: RunningSession) {
        guard !session.isOpenCodeSessionCreateInFlight,
              session.openCodeSessionID == nil,
              let baseURL = session.openCodeBaseURL else {
            return
        }
        session.isOpenCodeSessionCreateInFlight = true
        Task { @MainActor in
            do {
                let response = try await self.postJSON(
                    to: self.openCodeURL(baseURL: baseURL, path: "session", workingDirectory: session.workingDirectory),
                    body: [:]
                )
                guard let id = response["id"] as? String, !id.isEmpty else {
                    throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
                }
                guard self.sessions[session.sessionId] === session else { return }
                session.openCodeSessionID = id
                session.isOpenCodeSessionCreateInFlight = false
                self.emitStarted(session: session)
            } catch {
                session.isOpenCodeSessionCreateInFlight = false
                self.emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: "stderr",
                    text: "\(error.localizedDescription)\n"
                )
            }
        }
    }

    private func postOpenCodePrompt(_ text: String, session: RunningSession) async throws {
        guard let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
        }
        let url = openCodeURL(
            baseURL: baseURL,
            path: "session/\(openCodeSessionID)/prompt_async",
            workingDirectory: session.workingDirectory
        )
        _ = try await postJSON(
            to: url,
            body: [
                "parts": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        )
    }

    private func openCodeURL(baseURL: URL, path: String, workingDirectory: String?) -> URL {
        let url = path.split(separator: "/").reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let workingDirectory {
            components?.queryItems = [URLQueryItem(name: "directory", value: workingDirectory)]
        }
        return components?.url ?? url
    }

    private func postJSON(to url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw AgentSessionBridgeError.providerNotReady("OpenCode")
        }
        guard !data.isEmpty else { return [:] }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        return decoded as? [String: Any] ?? [:]
    }

    private func writeClaudeStreamJSON(_ text: String, to stdin: Pipe) throws {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func emitStarted(session: RunningSession) {
        eventSink?([
            "type": "provider.started",
            "sessionId": session.sessionId,
            "providerId": session.providerID.rawValue,
            "executablePath": session.executablePath,
            "arguments": session.arguments
        ])
    }

    private func emitOutput(
        sessionId: String,
        providerID: AgentSessionProviderID,
        stream: String,
        text: String
    ) {
        eventSink?([
            "type": "provider.output",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "stream": stream,
            "text": text
        ])
    }

    private final class RunningSession {
        let sessionId: String
        let providerID: AgentSessionProviderID
        let executablePath: String
        let arguments: [String]
        let workingDirectory: String?
        let process: Process
        let stdin: Pipe
        var codexAppServerSession: CodexAppServerSession?
        var openCodeBaseURL: URL?
        var openCodeSessionID: String?
        var isOpenCodeSessionCreateInFlight = false
        private var stdoutBuffer = Data()
        private var stderrBuffer = Data()

        init(
            sessionId: String,
            providerID: AgentSessionProviderID,
            executablePath: String,
            arguments: [String],
            workingDirectory: String?,
            process: Process,
            stdin: Pipe
        ) {
            self.sessionId = sessionId
            self.providerID = providerID
            self.executablePath = executablePath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.process = process
            self.stdin = stdin
        }

        func appendOutputData(_ data: Data, stream: String) -> [String] {
            if stream == "stdout" {
                return Self.appendOutputData(data, buffer: &stdoutBuffer)
            }
            return Self.appendOutputData(data, buffer: &stderrBuffer)
        }

        func flushBufferedOutput(stream: String) -> [String] {
            if stream == "stdout" {
                return Self.flushBufferedOutput(buffer: &stdoutBuffer)
            }
            return Self.flushBufferedOutput(buffer: &stderrBuffer)
        }

        private static func appendOutputData(_ data: Data, buffer: inout Data) -> [String] {
            buffer.append(data)
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                lines.append(String(decoding: lineData, as: UTF8.self) + "\n")
            }
            return lines
        }

        private static func flushBufferedOutput(buffer: inout Data) -> [String] {
            guard !buffer.isEmpty else { return [] }
            let text = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return [text]
        }
    }
}

private enum AgentSessionHTTPBridge {
    static func perform(request: AgentSessionBridgeRequest) async throws -> [String: Any] {
        guard let url = URL(string: try request.requiredString("url")),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AgentSessionBridgeError.missingParameter("url")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 30
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
