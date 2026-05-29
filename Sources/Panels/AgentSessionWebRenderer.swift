import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
            initialProviderID: panel.currentProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
    }

    func makeNSView(context: Context) -> NSView {
        let host = AgentSessionWebHostView()
        host.wantsLayer = true
        applyBackground(to: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? AgentSessionWebHostView else { return }
        context.coordinator.bind(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.currentProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        let webView = context.coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.onPointerDown = onRequestPanelFocus
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        applyBackground(to: host)
        applyBackground(to: webView)
        applyAppearance(to: webView)
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.loadShellIfNeeded()
            coordinator?.flushVisiblePaintIfReady()
        }
        host.onGeometryChanged = { [weak coordinator = context.coordinator] in
            coordinator?.flushVisiblePaintIfReady()
        }
        context.coordinator.loadShellIfNeeded()
        context.coordinator.flushVisiblePaintIfReady()
        if isFocused {
            context.coordinator.focus()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let host = nsView as? AgentSessionWebHostView {
            host.detachHostedWebViewIfOwned(coordinator.webView)
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
        }
    }

    private func applyBackground(to host: NSView) {
        host.wantsLayer = true
        host.layer?.backgroundColor = backgroundColor.cgColor
        host.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyAppearance(to webView: WKWebView) {
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
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
        private var isClosed = false
        private var isProviderStartPending = false
        private var processStore = AgentSessionProcessStore()
        private static let imagePreviewMaxBytes = 512 * 1024
        private static let imagePreviewTotalMaxBytes = 2 * 1024 * 1024
        var onHasActiveProviderChanged: ((Bool) -> Void)? {
            didSet {
                onHasActiveProviderChanged?(processStore.hasActiveProviderSession)
            }
        }
        var onProviderIDChanged: ((AgentSessionProviderID) -> Void)?

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
            processStore.activeProviderSink = { [weak self] hasActiveProvider in
                self?.onHasActiveProviderChanged?(hasActiveProvider)
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
            isClosed = false
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
            guard let webView, webView.window != nil else {
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
            webView.loadFileURL(indexURL, allowingReadAccessTo: Bundle.main.resourceURL ?? resourceDirectoryURL)
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
            isClosed = true
            processStore.closeAll()
            if let webView {
                webView.removeFromSuperview()
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
            guard message.frameInfo.isMainFrame else {
                replyHandler(["ok": false, "error": [:]], nil)
                return
            }
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

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if isInPageFragment(url, currentURL: webView.url) {
                decisionHandler(.allow)
                return
            }
            handleExternalLink(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                handleExternalLink(url)
            }
            return nil
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
              void (document.body && document.body.innerText);
              void (document.documentElement && document.documentElement.scrollHeight);
              return true;
            })()
            """
            webView.evaluateJavaScript(script) { result, error in
                _ = result
                _ = error
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
                    "rateLimitRows": [],
                    "copy": [
                        "start": String(localized: "agentSession.web.start", defaultValue: "Start"),
                        "stop": String(localized: "agentSession.web.stop", defaultValue: "Stop"),
                        "send": String(localized: "agentSession.web.send", defaultValue: "Send"),
                        "provider": String(localized: "agentSession.web.provider", defaultValue: "Provider"),
                        "rateLimits": String(localized: "agentSession.web.rateLimits", defaultValue: "Rate limits"),
                        "rateLimitUsageRemaining": String(
                            localized: "agentSession.web.rateLimit.usageRemaining",
                            defaultValue: "Usage remaining"
                        ),
                        "rateLimitPrimary": String(localized: "agentSession.web.rateLimit.primary", defaultValue: "Primary"),
                        "rateLimitSecondary": String(localized: "agentSession.web.rateLimit.secondary", defaultValue: "Secondary"),
                        "rateLimitWeekly": String(localized: "agentSession.web.rateLimit.weekly", defaultValue: "Weekly"),
                        "rateLimitMonthly": String(localized: "agentSession.web.rateLimit.monthly", defaultValue: "Monthly"),
                        "rateLimitResets": String(localized: "agentSession.web.rateLimit.resets", defaultValue: "resets"),
                        "voiceInput": String(localized: "agentSession.web.voiceInput", defaultValue: "Voice input"),
                        "promptPlaceholder": String(
                            localized: "agentSession.web.promptPlaceholder",
                            defaultValue: "Ask anything"
                        ),
                        "attachFile": String(
                            localized: "agentSession.web.attachFile",
                            defaultValue: "Attach file"
                        ),
                        "addFilesAndMore": String(
                            localized: "agentSession.web.addFilesAndMore",
                            defaultValue: "Add files and more"
                        ),
                        "addPhotosAndFiles": String(
                            localized: "agentSession.web.addPhotosAndFiles",
                            defaultValue: "Add photos & files"
                        ),
                        "removeAttachment": String(
                            localized: "agentSession.web.removeAttachment",
                            defaultValue: "Remove attachment"
                        ),
                        "browseWeb": String(localized: "agentSession.web.browseWeb", defaultValue: "Browse web"),
                        "autoContext": String(localized: "agentSession.web.autoContext", defaultValue: "Context"),
                        "tools": String(localized: "agentSession.web.tools", defaultValue: "Tools"),
                        "changePermissions": String(
                            localized: "agentSession.web.changePermissions",
                            defaultValue: "Change permissions"
                        ),
                        "permissionsDefault": String(
                            localized: "agentSession.web.permissions.default",
                            defaultValue: "Default permissions"
                        ),
                        "permissionsFullAccess": String(
                            localized: "agentSession.web.permissions.fullAccess",
                            defaultValue: "Full access"
                        ),
                        "permissionsAutoReview": String(
                            localized: "agentSession.web.permissions.autoReview",
                            defaultValue: "Auto-review"
                        ),
                        "permissionsCustom": String(
                            localized: "agentSession.web.permissions.custom",
                            defaultValue: "Custom (config.toml)"
                        ),
                        "reasoningEffortHigh": String(
                            localized: "agentSession.web.reasoningEffort.high",
                            defaultValue: "High"
                        ),
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
                        "composerNoResults": String(
                            localized: "agentSession.web.composerNoResults",
                            defaultValue: "No results"
                        ),
                        "planMode": String(localized: "agentSession.web.planMode", defaultValue: "Plan mode"),
                        "planSuggestionAction": String(
                            localized: "agentSession.web.planSuggestion.action",
                            defaultValue: "Use plan mode"
                        ),
                        "planSuggestionDismiss": String(
                            localized: "agentSession.web.planSuggestion.dismiss",
                            defaultValue: "Dismiss suggestion"
                        ),
                        "planSuggestionShortcut": String(
                            localized: "agentSession.web.planSuggestion.shortcut",
                            defaultValue: "Shift + Tab"
                        ),
                        "planSuggestionTitle": String(
                            localized: "agentSession.web.planSuggestion.title",
                            defaultValue: "Create a plan"
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
            case "app.pickFiles":
                return pickLocalFiles()
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
            case "provider.select":
                guard !processStore.hasActiveProviderSession,
                      !isProviderStartPending else {
                    throw AgentSessionBridgeError.sessionAlreadyRunning
                }
                let provider = try request.providerID()
                initialProviderID = provider
                onProviderIDChanged?(provider)
                return ["providerId": provider.rawValue]
            case "provider.start":
                guard !isClosed else {
                    throw AgentSessionBridgeError.invalidRequest
                }
                guard !processStore.hasActiveProviderSession,
                      !isProviderStartPending else {
                    throw AgentSessionBridgeError.sessionAlreadyRunning
                }
                isProviderStartPending = true
                defer {
                    isProviderStartPending = false
                }
                let provider = try request.providerID()
                initialProviderID = provider
                onProviderIDChanged?(provider)
                let configuredExecutablePaths = AgentExecutableResolver.cmuxConfiguredExecutablePaths()
                let plan = try await Task.detached(priority: .userInitiated) {
                    let resolver = AgentExecutableResolver(configuredExecutablePaths: configuredExecutablePaths)
                    return try resolver.resolve(provider)
                }.value
                guard !isClosed else {
                    throw AgentSessionBridgeError.invalidRequest
                }
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
                    text: request.requiredRawString("text")
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

        private func pickLocalFiles() -> [String: Any] {
            let panel = NSOpenPanel()
            panel.title = String(
                localized: "agentSession.web.addPhotosAndFiles",
                defaultValue: "Add photos & files"
            )
            panel.prompt = String(
                localized: "agentSession.web.addPhotosAndFiles",
                defaultValue: "Add photos & files"
            )
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.canCreateDirectories = false

            guard panel.runModal() == .OK else {
                return ["files": []]
            }

            var remainingImagePreviewBytes = Self.imagePreviewTotalMaxBytes
            return [
                "files": panel.urls.map {
                    pickedLocalFileDictionary($0, remainingImagePreviewBytes: &remainingImagePreviewBytes)
                }
            ]
        }

        private func pickedLocalFileDictionary(
            _ url: URL,
            remainingImagePreviewBytes: inout Int
        ) -> [String: Any] {
            let type = UTType(filenameExtension: url.pathExtension)
            let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
            let isImage = type?.conforms(to: .image) == true
            var file: [String: Any] = [
                "label": url.lastPathComponent,
                "path": url.path,
                "fsPath": url.path,
                "mimeType": mimeType,
                "isImage": isImage
            ]
            if isImage,
               let byteCount = imagePreviewByteCount(url),
               byteCount <= Self.imagePreviewMaxBytes,
               byteCount <= remainingImagePreviewBytes,
               let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               data.count <= byteCount {
                remainingImagePreviewBytes -= data.count
                file["dataUrl"] = "data:\(mimeType);base64,\(data.base64EncodedString())"
            }
            return file
        }

        private func imagePreviewByteCount(_ url: URL) -> Int? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  let size = attributes[.size] as? NSNumber else {
                return nil
            }
            let byteCount = size.intValue
            return byteCount >= 0 ? byteCount : nil
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

        private func handleExternalLink(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "mailto" else {
                return
            }

            guard scheme == "http" || scheme == "https" else {
                NSWorkspace.shared.open(url)
                return
            }

            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else {
                NSWorkspace.shared.open(url)
                return
            }

            _ = location.workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: true
            )
        }

        private func isInPageFragment(_ url: URL, currentURL: URL?) -> Bool {
            guard url.fragment != nil else { return false }
            if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
                return true
            }
            guard let currentURL else { return false }
            if url.isFileURL, currentURL.isFileURL {
                return (url.path as NSString).standardizingPath ==
                    (currentURL.path as NSString).standardizingPath
            }
            return url.scheme == currentURL.scheme &&
                url.host == currentURL.host &&
                url.path == currentURL.path
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
