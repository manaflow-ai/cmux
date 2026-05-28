import AppKit
import Darwin
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

@MainActor
final class AgentSessionWebHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedGeometryState: GeometryState?
    private var hasPendingGeometryNotification = false
    private weak var hostedWebView: WKWebView?

    private struct GeometryState: Equatable {
        let frame: CGRect
        let bounds: CGRect
        let windowNumber: Int?
        let superviewID: ObjectIdentifier?
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
        notifyGeometryChangedIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notifyGeometryChangedIfNeeded()
    }

    override func layout() {
        super.layout()
        if let hostedWebView, hostedWebView.superview === self {
            hostedWebView.frame = bounds
        }
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        markGeometryDirtyIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        markGeometryDirtyIfNeeded()
    }

    private func currentGeometryState() -> GeometryState {
        GeometryState(
            frame: frame,
            bounds: bounds,
            windowNumber: window?.windowNumber,
            superviewID: superview.map(ObjectIdentifier.init)
        )
    }

    private func markGeometryDirtyIfNeeded() {
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        guard !hasPendingGeometryNotification else { return }
        hasPendingGeometryNotification = true
        DispatchQueue.main.async { [weak self] in
            self?.notifyGeometryChangedIfNeeded()
        }
    }

    private func notifyGeometryChangedIfNeeded() {
        hasPendingGeometryNotification = false
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        lastReportedGeometryState = state
        geometryRevision &+= 1
        onGeometryChanged?()
    }

    func attachWebView(_ webView: WKWebView) {
        if webView.superview !== self {
            webView.removeFromSuperview()
            addSubview(webView, positioned: .above, relativeTo: nil)
        }
        hostedWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func detachHostedWebViewIfOwned(_ webView: WKWebView?) {
        guard let webView,
              webView.superview === self else {
            return
        }
        webView.removeFromSuperview()
        if hostedWebView === webView {
            hostedWebView = nil
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
    var onHasActiveProviderChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onHasActiveProviderChanged = onHasActiveProviderChanged
        }
    }
    var onProviderIDChanged: ((AgentSessionProviderID) -> Void)? {
        didSet {
            ownedCoordinator.onProviderIDChanged = onProviderIDChanged
        }
    }

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

    func rawString(_ key: String) -> String? {
        params[key] as? String
    }

    func requiredRawString(_ key: String) throws -> String {
        guard let value = rawString(key) else {
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
            _ = provider
            return String(
                localized: "agentSession.bridge.error.invalidProvider",
                defaultValue: "The selected provider is unavailable."
            )
        case .missingParameter(let parameter):
            _ = parameter
            return String(
                localized: "agentSession.bridge.error.missingParameter",
                defaultValue: "The request is incomplete."
            )
        case .unsupportedMethod(let method):
            _ = method
            return String(
                localized: "agentSession.bridge.error.unsupportedMethod",
                defaultValue: "This action is not supported."
            )
        case .sessionNotFound(let sessionId):
            _ = sessionId
            return String(
                localized: "agentSession.bridge.error.sessionNotFound",
                defaultValue: "The agent session is no longer available."
            )
        case .sessionAlreadyRunning:
            return String(
                localized: "agentSession.bridge.error.sessionAlreadyRunning",
                defaultValue: "An agent session is already running."
            )
        case .providerNotReady(let provider):
            _ = provider
            return String(
                localized: "agentSession.bridge.error.providerNotReady",
                defaultValue: "The provider is not ready yet."
            )
        case .unsupportedTransport(let transport):
            _ = transport
            return String(
                localized: "agentSession.bridge.error.unsupportedTransport",
                defaultValue: "Agent transport is not supported."
            )
        }
    }
}

struct OpenCodeServerAuth: Equatable {
    let authorizationHeader: String

    init?(environment: [String: String]) {
        guard let password = environment["OPENCODE_SERVER_PASSWORD"],
              !password.isEmpty else {
            return nil
        }
        let username = environment["OPENCODE_SERVER_USERNAME"].flatMap { value -> String? in
            value.isEmpty ? nil : value
        } ?? "opencode"
        let token = "\(username):\(password)"
        authorizationHeader = "Basic \(Data(token.utf8).base64EncodedString())"
    }
}

struct ClaudeStreamJSONAccumulator {
    private var emittedTextByMessageID: [String: String] = [:]
    private var currentMessageID: String?
    private var pendingDeltaText = ""
    private var emittedAnyAssistantText = false

    mutating func consumeLine(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let messageID = assistantMessageID(fromMessageStart: object) {
            currentMessageID = messageID
            pendingDeltaText = ""
            return []
        }

        if let delta = assistantTextDelta(from: object), !delta.isEmpty {
            emittedAnyAssistantText = true
            if let currentMessageID {
                emittedTextByMessageID[currentMessageID, default: ""] += delta
            } else {
                pendingDeltaText += delta
            }
            return [delta]
        }

        if !emittedAnyAssistantText,
           object["type"] as? String == "result",
           let result = object["result"] as? String,
           !result.isEmpty {
            emittedAnyAssistantText = true
            return [result]
        }

        return []
    }

    private func assistantMessageID(fromMessageStart object: [String: Any]) -> String? {
        guard object["type"] as? String == "message_start",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let messageID = message["id"] as? String,
              !messageID.isEmpty else {
            return nil
        }
        return messageID
    }

    private mutating func assistantTextDelta(from object: [String: Any]) -> String? {
        if object["type"] as? String == "content_block_delta",
           let delta = object["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        guard object["type"] as? String == "assistant" else {
            return nil
        }
        let message = (object["message"] as? [String: Any]) ?? object
        let fullText = Self.contentText(from: message["content"])
        guard !fullText.isEmpty else { return nil }

        let messageID = (message["id"] as? String) ?? "assistant"
        let previousText = emittedTextByMessageID[messageID] ??
            (fullText.hasPrefix(pendingDeltaText) ? pendingDeltaText : "")
        emittedTextByMessageID[messageID] = fullText
        if currentMessageID == messageID {
            currentMessageID = nil
        }
        pendingDeltaText = ""
        if fullText.hasPrefix(previousText) {
            return String(fullText.dropFirst(previousText.count))
        }
        return fullText
    }

    private static func contentText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let part = content as? [String: Any] {
            if let type = part["type"] as? String,
               type != "text" {
                return ""
            }
            return part["text"] as? String ?? ""
        }
        if let parts = content as? [Any] {
            return parts.map(contentText(from:)).joined()
        }
        return ""
    }
}

struct OpenCodeEventStreamParser {
    private var dataLines: [String] = []

    mutating func consumeLine(_ line: String) -> [[String: Any]] {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.isEmpty else {
            return flush()
        }
        guard line.hasPrefix("data:") else {
            return []
        }

        var data = String(line.dropFirst("data:".count))
        if data.hasPrefix(" ") {
            data.removeFirst()
        }
        dataLines.append(data)
        return []
    }

    mutating func flush() -> [[String: Any]] {
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return []
        }
        return [object]
    }
}

struct OpenCodeEventTextAccumulator {
    private var messageRoleByID: [String: String] = [:]
    private var messageIDByPartID: [String: String] = [:]
    private var isTextPartByID: [String: Bool] = [:]
    private var textByPartID: [String: String] = [:]
    private var emittedCharacterCountByPartID: [String: Int] = [:]

    mutating func consumeEvent(_ event: [String: Any], sessionID: String) -> [String] {
        guard let type = event["type"] as? String,
              let properties = event["properties"] as? [String: Any],
              Self.eventSessionID(properties) == sessionID else {
            return []
        }

        switch type {
        case "message.updated":
            return consumeMessageUpdated(properties)
        case "message.part.updated":
            return consumePartUpdated(properties)
        case "message.part.delta":
            return consumePartDelta(properties)
        default:
            return []
        }
    }

    private static func eventSessionID(_ properties: [String: Any]) -> String? {
        firstString(
            properties["sessionID"],
            properties["sessionId"],
            properties["session_id"],
            nestedString(properties, "info", "sessionID"),
            nestedString(properties, "info", "sessionId"),
            nestedString(properties, "info", "session_id"),
            nestedString(properties, "message", "sessionID"),
            nestedString(properties, "message", "sessionId"),
            nestedString(properties, "message", "session_id"),
            nestedString(properties, "part", "sessionID"),
            nestedString(properties, "part", "sessionId"),
            nestedString(properties, "part", "session_id")
        )
    }

    private static func nestedString(_ dictionary: [String: Any], _ key: String, _ nestedKey: String) -> String? {
        guard let nested = dictionary[key] as? [String: Any] else { return nil }
        return nested[nestedKey] as? String
    }

    private static func firstString(_ values: Any?...) -> String? {
        for value in values {
            guard let string = value as? String else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private mutating func consumeMessageUpdated(_ properties: [String: Any]) -> [String] {
        guard let info = properties["info"] as? [String: Any],
              let messageID = info["id"] as? String,
              let role = info["role"] as? String else {
            return []
        }

        messageRoleByID[messageID] = role
        guard role == "assistant" else { return [] }
        let partIDs = messageIDByPartID.compactMap { partID, candidateMessageID in
            candidateMessageID == messageID ? partID : nil
        }
        return partIDs.flatMap { flushPart($0) }
    }

    private mutating func consumePartUpdated(_ properties: [String: Any]) -> [String] {
        guard let part = properties["part"] as? [String: Any],
              let partID = part["id"] as? String,
              let messageID = part["messageID"] as? String else {
            return []
        }

        messageIDByPartID[partID] = messageID
        guard part["type"] as? String == "text",
              part["ignored"] as? Bool != true,
              let text = part["text"] as? String else {
            return []
        }

        isTextPartByID[partID] = true
        let existingText = textByPartID[partID] ?? ""
        if text.count >= existingText.count {
            textByPartID[partID] = text
        }
        return flushPart(partID)
    }

    private mutating func consumePartDelta(_ properties: [String: Any]) -> [String] {
        guard properties["field"] as? String == "text",
              let partID = properties["partID"] as? String,
              let messageID = properties["messageID"] as? String,
              let delta = properties["delta"] as? String,
              !delta.isEmpty else {
            return []
        }

        messageIDByPartID[partID] = messageID
        textByPartID[partID, default: ""] += delta
        return flushPart(partID)
    }

    private mutating func flushPart(_ partID: String) -> [String] {
        guard isTextPartByID[partID] == true,
              let messageID = messageIDByPartID[partID],
              messageRoleByID[messageID] == "assistant",
              let text = textByPartID[partID],
              !text.isEmpty else {
            return []
        }

        let emittedCharacterCount = emittedCharacterCountByPartID[partID] ?? 0
        guard text.count > emittedCharacterCount else { return [] }
        emittedCharacterCountByPartID[partID] = text.count
        return [String(text.dropFirst(emittedCharacterCount))]
    }
}

@MainActor
final class CodexAppServerSession {
    typealias DataWriter = (Data) throws -> Void
    typealias OutputSink = (_ stream: String, _ text: String) -> Void
    typealias ActivitySink = (_ activity: [String: Any]) -> Void
    typealias FailureSink = (_ details: String?) -> Void

    private let workingDirectory: String?
    private let writeData: DataWriter
    private let outputSink: OutputSink
    private let activitySink: ActivitySink
    private let failureSink: FailureSink
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var didInitialize = false
    private var threadStartRequestID: Int?
    private var threadID: String?
    private var queuedInputs: [String] = []
    private var stdoutBuffer = ""
    private var didFailStartup = false

    init(
        workingDirectory: String?,
        writeData: @escaping DataWriter,
        outputSink: @escaping OutputSink,
        activitySink: @escaping ActivitySink = { _ in },
        failureSink: @escaping FailureSink = { _ in }
    ) {
        self.workingDirectory = workingDirectory
        self.writeData = writeData
        self.outputSink = outputSink
        self.activitySink = activitySink
        self.failureSink = failureSink
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
        guard !text.isEmpty else { return }
        guard !didFailStartup else {
            throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
        }
        guard let threadID else {
            queuedInputs.append(text)
            if didInitialize {
                try startThreadIfNeeded()
            }
            return
        }
        try sendTurnStart(threadID: threadID, text: text)
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
            handleRPCError(id: id, error: error)
            return
        }
        handleResponse(id: id, result: object["result"] as? [String: Any])
    }

    private func handleResponse(id: Int, result: [String: Any]?) {
        if id == initializeRequestID {
            initializeRequestID = nil
            didInitialize = true
            do {
                try sendNotification(method: "initialized")
                try startThreadIfNeeded()
            } catch {
                failStartup(details: error.localizedDescription)
            }
            return
        }

        if id == threadStartRequestID {
            guard let thread = result?["thread"] as? [String: Any],
                  let id = thread["id"] as? String else {
                failStartup(details: nil)
                return
            }
            threadID = id
            threadStartRequestID = nil
            drainQueuedInputs()
            return
        }
    }

    private func handleRPCError(id: Int, error: [String: Any]) {
        let details = error["message"] as? String
        if id == initializeRequestID || id == threadStartRequestID {
            failStartup(details: details)
            return
        }
        emitCodexRPCFailure(details: details)
    }

    private func handleNotification(method: String, params: [String: Any]?) {
        switch method {
        case "thread/started":
            if threadID == nil,
               let thread = params?["thread"] as? [String: Any],
               let id = thread["id"] as? String {
                threadID = id
                threadStartRequestID = nil
                drainQueuedInputs()
            }
        case "item/agentMessage/delta":
            if let delta = params?["delta"] as? String {
                outputSink("stdout", delta)
            }
        case "item/started":
            if let item = params?["item"] as? [String: Any] {
                emitActivity(for: item, defaultStatus: "inProgress")
            }
        case "item/completed":
            if let item = params?["item"] as? [String: Any] {
                emitActivity(for: item, defaultStatus: "completed")
            }
        case "item/commandExecution/outputDelta":
            guard let itemID = params?["itemId"] as? String else { break }
            emitActivity(
                activityID: itemID,
                kind: "command",
                status: "inProgress",
                action: Self.commandAction(status: "inProgress"),
                detail: nil,
                outputDelta: params?["delta"] as? String
            )
        case "item/fileChange/patchUpdated":
            guard let itemID = params?["itemId"] as? String else { break }
            let summary = Self.fileChangeSummary(from: params?["changes"])
            emitActivity(
                activityID: itemID,
                kind: "fileChange",
                status: "inProgress",
                action: Self.fileChangeAction(changeType: summary.changeType, status: "inProgress"),
                detail: summary.path
            )
        case "error":
            let error = params?["error"] as? [String: Any]
            let details = error?["message"] as? String
            if threadID == nil || initializeRequestID != nil || threadStartRequestID != nil {
                failStartup(details: details)
            } else {
                emitCodexRPCFailure(details: details)
            }
        case "warning", "guardianWarning", "configWarning", "deprecationNotice":
            outputSink("stderr", codexMessage(from: params) ?? Self.unknownWarningMessage())
        default:
            break
        }
    }

    private func emitActivity(for item: [String: Any], defaultStatus: String) {
        guard let itemID = item["id"] as? String,
              let itemType = item["type"] as? String else {
            return
        }
        let status = Self.activityStatus(from: item, defaultStatus: defaultStatus)
        switch itemType {
        case "commandExecution":
            emitActivity(
                activityID: itemID,
                kind: "command",
                status: status,
                action: Self.commandAction(status: status),
                detail: Self.commandText(from: item)
            )
        case "fileChange":
            let summary = Self.fileChangeSummary(from: item["changes"])
            emitActivity(
                activityID: itemID,
                kind: "fileChange",
                status: status,
                action: Self.fileChangeAction(changeType: summary.changeType, status: status),
                detail: summary.path
            )
        default:
            break
        }
    }

    private func emitActivity(
        activityID: String,
        kind: String,
        status: String,
        action: String,
        detail: String?,
        outputDelta: String? = nil
    ) {
        var activity: [String: Any] = [
            "activityId": activityID,
            "kind": kind,
            "status": status,
            "action": action
        ]
        if let detail, !detail.isEmpty {
            activity["detail"] = detail
        }
        if let outputDelta, !outputDelta.isEmpty {
            activity["outputDelta"] = outputDelta
        }
        activitySink(activity)
    }

    private static func activityStatus(from item: [String: Any], defaultStatus: String) -> String {
        if let parsedCommand = item["parsedCmd"] as? [String: Any],
           let isFinished = parsedCommand["isFinished"] as? Bool,
           !isFinished {
            return "inProgress"
        }
        let rawStatus = (item["executionStatus"] as? String) ?? (item["status"] as? String)
        switch rawStatus?.lowercased() {
        case "interrupted", "canceled", "cancelled", "stopped":
            return "stopped"
        case "failed", "failure", "error":
            return "failed"
        case "inprogress", "in_progress", "running", "started":
            return "inProgress"
        case "completed", "complete", "succeeded", "success":
            return "completed"
        default:
            return defaultStatus
        }
    }

    private static func commandAction(status: String) -> String {
        switch status {
        case "inProgress":
            return String(localized: "agentSession.codex.activity.command.running", defaultValue: "Running")
        case "stopped":
            return String(localized: "agentSession.codex.activity.command.stopped", defaultValue: "Stopped")
        default:
            return String(localized: "agentSession.codex.activity.command.ran", defaultValue: "Ran")
        }
    }

    private static func commandText(from item: [String: Any]) -> String? {
        if let parsedCommand = item["parsedCmd"] as? [String: Any] {
            for key in ["cmd", "command", "name"] {
                if let value = nonEmptyString(parsedCommand[key]) {
                    return value
                }
            }
        }
        for key in ["command", "cmd", "commandText", "name"] {
            if let value = nonEmptyString(item[key]) {
                return value
            }
        }
        if let command = item["command"] as? [Any] {
            let text = command.compactMap { $0 as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func fileChangeAction(changeType: String?, status: String) -> String {
        switch (changeType, status) {
        case ("add", "inProgress"):
            return String(localized: "agentSession.codex.activity.file.creating", defaultValue: "Creating")
        case ("add", _):
            return String(localized: "agentSession.codex.activity.file.created", defaultValue: "Created")
        case ("delete", "inProgress"):
            return String(localized: "agentSession.codex.activity.file.deleting", defaultValue: "Deleting")
        case ("delete", _):
            return String(localized: "agentSession.codex.activity.file.deleted", defaultValue: "Deleted")
        case (_, "inProgress"):
            return String(localized: "agentSession.codex.activity.file.editing", defaultValue: "Editing")
        default:
            return String(localized: "agentSession.codex.activity.file.edited", defaultValue: "Edited")
        }
    }

    private static func fileChangeSummary(from value: Any?) -> (path: String?, changeType: String?) {
        if let changes = value as? [String: Any] {
            for key in changes.keys.sorted() {
                let change = changes[key] as? [String: Any]
                return (key, change?["type"] as? String)
            }
        }
        if let changes = value as? [[String: Any]],
           let first = changes.first {
            let path = nonEmptyString(first["path"]) ?? nonEmptyString(first["filePath"]) ?? nonEmptyString(first["name"])
            return (path, first["type"] as? String)
        }
        return (nil, nil)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        let string: String?
        if let value = value as? String {
            string = value
        } else {
            string = nil
        }
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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
                emitCodexRPCFailure(error)
            }
            return
        }

        do {
            try sendJSONObject(["id": id, "result": result])
        } catch {
            emitCodexRPCFailure(error)
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
                emitCodexRPCFailure(error)
            }
        }
    }

    private func startThreadIfNeeded() throws {
        guard !didFailStartup else {
            throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.codex.displayName)
        }
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

    private func failStartup(details: String?) {
        guard !didFailStartup else { return }
        didFailStartup = true
        initializeRequestID = nil
        didInitialize = false
        threadStartRequestID = nil
        threadID = nil
        queuedInputs.removeAll()
        emitCodexRPCFailure(details: details)
        failureSink(details)
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

    private func emitCodexRPCFailure(_ error: Error) {
#if DEBUG
        cmuxDebugLog("agentSession.codex.rpc.failed error=\(error.localizedDescription)")
#endif
        outputSink("stderr", Self.rpcFailedMessage())
    }

    private func emitCodexRPCFailure(details: String?) {
#if DEBUG
        if let details, !details.isEmpty {
            cmuxDebugLog("agentSession.codex.rpc.failed details=\(details)")
        }
#else
        _ = details
#endif
        outputSink("stderr", Self.rpcFailedMessage())
    }

    private static func rpcFailedMessage() -> String {
        String(localized: "agentSession.codex.error.rpcFailed", defaultValue: "Codex app-server request failed.")
    }

    private static func unknownWarningMessage() -> String {
        String(localized: "agentSession.codex.warning.unknown", defaultValue: "Codex app-server reported a warning.")
    }
}

private func agentSessionIsLoopbackURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

@MainActor
private final class AgentSessionProcessStore {
    struct StartedSession {
        let sessionId: String
    }

    var eventSink: (([String: Any]) -> Void)?
    var activeProviderSink: ((Bool) -> Void)? {
        didSet {
            emitActiveProviderStateIfNeeded()
        }
    }
    var hasActiveProviderSession: Bool {
        !sessions.isEmpty
    }
    private var sessions: [String: RunningSession] = [:]
    private var lastEmittedHasActiveProviderSession: Bool?

    func start(plan: AgentSessionLaunchPlan, workingDirectory: String?) throws -> StartedSession {
        guard sessions.isEmpty else {
            throw AgentSessionBridgeError.sessionAlreadyRunning
        }
        let sessionId = UUID().uuidString
        let process = Process()
        let launchArguments = try Self.processArguments(for: plan)
        let launchEnvironment = plan.environment(overridingWorkingDirectory: workingDirectory)
        process.executableURL = plan.executableURL
        process.arguments = launchArguments
        process.environment = launchEnvironment
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .standardizedFileURL
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let openCodeAuth = OpenCodeServerAuth(environment: launchEnvironment)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let running = RunningSession(
            sessionId: sessionId,
            providerID: plan.provider,
            executablePath: plan.executableURL.path,
            arguments: launchArguments,
            workingDirectory: workingDirectory,
            process: process,
            stdin: stdin,
            openCodeAuthorizationHeader: openCodeAuth?.authorizationHeader
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
                },
                activitySink: { [weak self] activity in
                    self?.emitActivity(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        activity: activity
                    )
                },
                failureSink: { [weak self] _ in
                    self?.failSession(sessionId: sessionId, status: 1)
                }
            )
        }
        sessions[sessionId] = running

        installReadHandler(stdout.fileHandleForReading, sessionId: sessionId, stream: "stdout")
        installReadHandler(stderr.fileHandleForReading, sessionId: sessionId, stream: "stderr")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                session.pendingExitStatus = process.terminationStatus
                self.finishSessionIfExitedAndDrained(session)
            }
        }

        do {
            try process.run()
            emitActiveProviderStateIfNeeded()
            try running.codexAppServerSession?.start()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            running.openCodeEventTask?.cancel()
            sessions.removeValue(forKey: sessionId)
            emitActiveProviderStateIfNeeded()
            throw error
        }

        if plan.provider != .opencode {
            emitStarted(session: running)
        }
        return StartedSession(sessionId: sessionId)
    }

    private static func processArguments(for plan: AgentSessionLaunchPlan) throws -> [String] {
        guard plan.provider == .opencode else { return plan.arguments }
        return plan.arguments(assigningOpenCodePort: try allocateLoopbackPort())
    }

    private static func allocateLoopbackPort() throws -> Int {
        for _ in 0..<8 {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            defer { Darwin.close(fd) }

            var yes: Int32 = 1
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.getsockname(fd, sockaddrPointer, &length)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }

        throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.opencode.displayName)
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
        session.openCodeEventTask?.cancel()
        session.process.terminate()
    }

    func closeAll() {
        for session in sessions.values {
            session.openCodeEventTask?.cancel()
            session.process.terminate()
        }
        sessions.removeAll()
        emitActiveProviderStateIfNeeded()
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
                    session.drainedStreams.insert(stream)
                    self.finishSessionIfExitedAndDrained(session)
                    return
                }
                for text in session.appendOutputData(data, stream: stream) {
                    self.handleOutputLine(text, session: session, stream: stream)
                }
            }
        }
    }

    private func finishSessionIfExitedAndDrained(_ session: RunningSession) {
        guard let status = session.pendingExitStatus,
              session.drainedStreams.isSuperset(of: ["stdout", "stderr"]),
              sessions[session.sessionId] === session else {
            return
        }
        sessions.removeValue(forKey: session.sessionId)
        session.openCodeEventTask?.cancel()
        emitActiveProviderStateIfNeeded()
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func failSession(sessionId: String, status: Int32) {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            return
        }
        emitActiveProviderStateIfNeeded()
        session.openCodeEventTask?.cancel()
        if session.process.isRunning {
            session.process.terminate()
        }
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
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

        if stream == "stdout",
           session.providerID == .claude {
            for delta in session.consumeClaudeStreamJSONLine(text) {
                emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: stream,
                    text: delta
                )
            }
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
        guard let url = rawURL.flatMap(URL.init(string:)),
              agentSessionIsLoopbackURL(url) else {
            return nil
        }
        return url
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
                    body: [:],
                    authorizationHeader: session.openCodeAuthorizationHeader
                )
                guard let id = response["id"] as? String, !id.isEmpty else {
                    throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
                }
                guard self.sessions[session.sessionId] === session else { return }
                session.openCodeSessionID = id
                session.isOpenCodeSessionCreateInFlight = false
                self.startOpenCodeEventStream(session)
                self.emitStarted(session: session)
            } catch {
                session.isOpenCodeSessionCreateInFlight = false
                guard let removedSession = self.sessions.removeValue(forKey: session.sessionId),
                      removedSession === session else {
                    return
                }
                self.emitActiveProviderStateIfNeeded()
                session.openCodeEventTask?.cancel()
                if session.process.isRunning {
                    session.process.terminate()
                }
                let message = (error as? AgentSessionBridgeError)?.localizedDescription
                    ?? String(
                        localized: "agentSession.opencode.error.sessionCreateFailed",
                        defaultValue: "OpenCode session could not be created."
                    )
                self.emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: "stderr",
                    text: "\(message)\n"
                )
                self.emitExit(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    status: 1
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
            ],
            authorizationHeader: session.openCodeAuthorizationHeader
        )
    }

    private func startOpenCodeEventStream(_ session: RunningSession) {
        guard session.openCodeEventTask == nil,
              let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            return
        }
        let url = openCodeURL(baseURL: baseURL, path: "event", workingDirectory: session.workingDirectory)
        let authorizationHeader = session.openCodeAuthorizationHeader
        let sessionId = session.sessionId

        session.openCodeEventTask = Task { @MainActor [weak self] in
            await self?.consumeOpenCodeEventStream(
                sessionId: sessionId,
                openCodeSessionID: openCodeSessionID,
                url: url,
                authorizationHeader: authorizationHeader
            )
        }
    }

    private func consumeOpenCodeEventStream(
        sessionId: String,
        openCodeSessionID: String,
        url: URL,
        authorizationHeader: String?
    ) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.opencode.displayName)
            }

            var parser = OpenCodeEventStreamParser()
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                for event in parser.consumeLine(line) {
                    handleOpenCodeEvent(event, sessionId: sessionId, openCodeSessionID: openCodeSessionID)
                }
            }
            for event in parser.flush() {
                handleOpenCodeEvent(event, sessionId: sessionId, openCodeSessionID: openCodeSessionID)
            }
        } catch {
            guard !Task.isCancelled else { return }
#if DEBUG
            cmuxDebugLog("agentSession.opencode.eventStream.failed error=\(error.localizedDescription)")
#endif
            failOpenCodeEventStream(
                sessionId: sessionId,
                openCodeSessionID: openCodeSessionID,
                details: error.localizedDescription
            )
        }
    }

    private func failOpenCodeEventStream(sessionId: String, openCodeSessionID: String, details: String?) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }
        let message = String(
            localized: "agentSession.opencode.error.eventStreamFailed",
            defaultValue: "OpenCode event stream disconnected."
        )
        let suffix = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputText: String
        if let suffix = suffix, !suffix.isEmpty {
            outputText = "\(message) \(suffix)\n"
        } else {
            outputText = "\(message)\n"
        }
        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: "stderr",
            text: outputText
        )
        failSession(sessionId: sessionId, status: 1)
    }

    private func handleOpenCodeEvent(_ event: [String: Any], sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }

        for output in session.consumeOpenCodeEvent(event, openCodeSessionID: openCodeSessionID) {
            emitOutput(
                sessionId: session.sessionId,
                providerID: session.providerID,
                stream: "stdout",
                text: output
            )
        }
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

    private func postJSON(
        to url: URL,
        body: [String: Any],
        authorizationHeader: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
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

    private func emitActivity(
        sessionId: String,
        providerID: AgentSessionProviderID,
        activity: [String: Any]
    ) {
        var event = activity
        event["type"] = "provider.activity"
        event["sessionId"] = sessionId
        event["providerId"] = providerID.rawValue
        eventSink?(event)
    }

    private func emitExit(
        sessionId: String,
        providerID: AgentSessionProviderID,
        status: Int32
    ) {
        eventSink?([
            "type": "provider.exit",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "status": status
        ])
    }

    private func emitActiveProviderStateIfNeeded() {
        let hasActiveProviderSession = self.hasActiveProviderSession
        guard lastEmittedHasActiveProviderSession != hasActiveProviderSession else { return }
        lastEmittedHasActiveProviderSession = hasActiveProviderSession
        activeProviderSink?(hasActiveProviderSession)
    }

    private final class RunningSession {
        let sessionId: String
        let providerID: AgentSessionProviderID
        let executablePath: String
        let arguments: [String]
        let workingDirectory: String?
        let process: Process
        let stdin: Pipe
        let openCodeAuthorizationHeader: String?
        var codexAppServerSession: CodexAppServerSession?
        private var claudeStreamJSONAccumulator = ClaudeStreamJSONAccumulator()
        var openCodeBaseURL: URL?
        var openCodeSessionID: String?
        var isOpenCodeSessionCreateInFlight = false
        var openCodeEventTask: Task<Void, Never>?
        var pendingExitStatus: Int32?
        var drainedStreams: Set<String> = []
        private var stdoutBuffer = Data()
        private var stderrBuffer = Data()
        private var openCodeEventTextAccumulator = OpenCodeEventTextAccumulator()

        init(
            sessionId: String,
            providerID: AgentSessionProviderID,
            executablePath: String,
            arguments: [String],
            workingDirectory: String?,
            process: Process,
            stdin: Pipe,
            openCodeAuthorizationHeader: String?
        ) {
            self.sessionId = sessionId
            self.providerID = providerID
            self.executablePath = executablePath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.process = process
            self.stdin = stdin
            self.openCodeAuthorizationHeader = openCodeAuthorizationHeader
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

        func consumeClaudeStreamJSONLine(_ line: String) -> [String] {
            claudeStreamJSONAccumulator.consumeLine(line)
        }

        func consumeOpenCodeEvent(_ event: [String: Any], openCodeSessionID: String) -> [String] {
            openCodeEventTextAccumulator.consumeEvent(event, sessionID: openCodeSessionID)
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
        guard agentSessionIsLoopbackURL(url) else {
            throw AgentSessionBridgeError.invalidRequest
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
