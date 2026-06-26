import AppKit
import CmuxAgentChat
import CmuxFoundation
import WebKit

@MainActor
final class AgentSessionWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
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
    private var trustedShellURL: URL?
    private var hasFinishedNavigation = false
    private var hasCompletedVisiblePaintFlush = false
    private var isPanelFocused = false
    private var isClosed = false
    private var isProviderStartPending = false
    private var processStore = AgentSessionProcessStore()
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
            trustedShellURL = nil
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
        guard let resourceDirectoryURL = Bundle.main.resourceURL else {
            return
        }
        let indexURL = Self.shellURL(
            rendererKind: rendererKind,
            resourceDirectoryURL: resourceDirectoryURL
        )
        trustedShellURL = indexURL.normalizedTrustedFileURL
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
              window.firstResponder?.responderChain(contains: webView) ?? false else {
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
        trustedShellURL = nil
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard isTrustedBridgeFrame(message.frameInfo) else {
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
                replyHandler(["ok": false, "error": ["code": error.code, "userMessage": error.localizedDescription]], nil)
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
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let isMainFrameNavigation = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrameNavigation else {
            decisionHandler(.allow)
            return
        }

        if url.isTrustedShellURL(expected: trustedShellURL) {
            decisionHandler(.allow)
            return
        }

        if url.isInPageFragment(currentURL: webView.url) {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            handleExternalLink(url)
        }
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

    private func isTrustedBridgeFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame else {
            return false
        }
        return frameInfo.request.url?.isTrustedShellURL(expected: trustedShellURL) ?? false
    }

    nonisolated static func shellURL(
        rendererKind: AgentSessionRendererKind,
        resourceDirectoryURL: URL
    ) -> URL {
        rendererKind.resourceHTMLPathComponents.reduce(resourceDirectoryURL) {
            $0.appendingPathComponent($1, isDirectory: false)
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
                    "rateLimitDaysFormat": String(localized: "agentSession.web.rateLimit.daysFormat", defaultValue: "%@d"),
                    "rateLimitHoursFormat": String(localized: "agentSession.web.rateLimit.hoursFormat", defaultValue: "%@h"),
                    "rateLimitMinutesFormat": String(localized: "agentSession.web.rateLimit.minutesFormat", defaultValue: "%@m"),
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
                    "copyOutput": String(
                        localized: "agentSession.web.copyOutput",
                        defaultValue: "Copy output"
                    ),
                    "copyAssistantMessage": String(
                        localized: "agentSession.web.copyAssistantMessage",
                        defaultValue: "Copy"
                    ),
                    "copiedAssistantMessage": String(
                        localized: "agentSession.web.copiedAssistantMessage",
                        defaultValue: "Copied"
                    ),
                    "copyUserMessage": String(
                        localized: "agentSession.web.copyUserMessage",
                        defaultValue: "Copy message"
                    ),
                    "copiedUserMessage": String(
                        localized: "agentSession.web.copiedUserMessage",
                        defaultValue: "Copied"
                    ),
                    "shellLabel": String(
                        localized: "agentSession.web.shellLabel",
                        defaultValue: "Shell"
                    ),
                    "copyShellContents": String(
                        localized: "agentSession.web.copyShellContents",
                        defaultValue: "Copy shell contents"
                    ),
                    "copiedShellContents": String(
                        localized: "agentSession.web.copiedShellContents",
                        defaultValue: "Copied shell contents"
                    ),
                    "collapseShell": String(
                        localized: "agentSession.web.collapseShell",
                        defaultValue: "Collapse shell"
                    ),
                    "shellSuccess": String(
                        localized: "agentSession.web.shellSuccess",
                        defaultValue: "Success"
                    ),
                    "showMore": String(
                        localized: "agentSession.web.showMore",
                        defaultValue: "Show more"
                    ),
                    "showLess": String(
                        localized: "agentSession.web.showLess",
                        defaultValue: "Show less"
                    ),
                    "browseWeb": String(localized: "agentSession.web.browseWeb", defaultValue: "Browse web"),
                    "autoContext": String(localized: "agentSession.web.autoContext", defaultValue: "Context"),
                    "includeIdeContext": String(
                        localized: "agentSession.web.includeIdeContext",
                        defaultValue: "Include IDE context"
                    ),
                    "ideContext": String(
                        localized: "agentSession.web.ideContext",
                        defaultValue: "IDE context"
                    ),
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
            return await pickLocalFiles()
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
            let session = try await processStore.start(
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
                permissionMode: request.permissionMode(),
                text: request.requiredRawString("text")
            )
            return ["sent": true]
        case "provider.stop":
            try processStore.stop(sessionId: request.requiredString("sessionId"))
            return ["stopped": true]
        default:
            throw AgentSessionBridgeError.unsupportedMethod(request.method)
        }
    }

    private func pickLocalFiles() async -> [String: Any] {
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

        let urls = panel.urls
        return await Task.detached(priority: .userInitiated) {
            ["files": LocalAttachmentEncoder().encode(urls)]
        }.value
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
}
