import AppKit
import CmuxKanbanCore
import CmuxSettings
import WebKit

/// Bridges the Kanban board webview to its native ``KanbanBoardRepository``.
///
/// Mirrors the security and lifecycle shape of
/// ``AgentSessionWebRendererCoordinator`` (trusted-frame gate, shell loading,
/// initial-paint flush) but trades the agent process plumbing for board CRUD:
/// it loads/saves one ``KanbanBoard`` per workspace and pushes a
/// server-authoritative `kanban.boardUpdated` event after every mutation.
///
/// The webview is the *control* surface only — it never owns board state. Every
/// mutation round-trips through the repository and the whole board is re-emitted,
/// so the React reducer reconciles from a single source of truth.
@MainActor
final class KanbanWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    var webView: AgentSessionWebView?
    private var panelId = UUID()
    private var workspaceId = UUID()
    private var rendererKind: KanbanRendererKind = .react
    private var theme: AgentSessionWebTheme = .resolve(
        appearance: .fromConfig(GhosttyConfig.load())
    )
    private var loadedRendererKind: KanbanRendererKind?
    private var trustedShellURL: URL?
    private var hasFinishedNavigation = false
    private var hasCompletedVisiblePaintFlush = false
    private var isPanelFocused = false
    private var isClosed = false

    /// Working directory of the hosting workspace; the root for the native
    /// backend's per-card worktrees and its fallback run directory. Set on
    /// ``bind(panelId:workspaceId:workingDirectory:rendererKind:theme:isFocused:)``.
    private var workingDirectory: String?

    /// The dispatch engine — the single, serialized source of truth for this
    /// workspace's board. Created lazily once the workspace id is known; the
    /// coordinator subscribes to its streams and projects them to the webview,
    /// and never mutates board state itself.
    private var engine: KanbanEngine?
    private var didStartEngine = false
    private var subscriptions: [Task<Void, Never>] = []

    func bind(
        panelId: UUID,
        workspaceId: UUID,
        workingDirectory: String?,
        rendererKind: KanbanRendererKind,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) {
        self.panelId = panelId
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory
        if self.rendererKind != rendererKind {
            loadedRendererKind = nil
            trustedShellURL = nil
            hasFinishedNavigation = false
            hasCompletedVisiblePaintFlush = false
        }
        self.rendererKind = rendererKind
        isPanelFocused = isFocused
        let themeChanged = self.theme != theme
        self.theme = theme
        if themeChanged {
            applyThemeToLoadedPage()
        }
    }

    func ensureWebView(onPointerDown: @escaping () -> Void) -> AgentSessionWebView {
        if let webView {
            webView.onPointerDown = onPointerDown
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        // The board ships as ES modules: `kanban.html` loads `./main.mjs`, which
        // statically imports `./chunks/*.mjs`. Over `file://` the document origin
        // is `null`, so WebKit rejects those cross-origin module fetches
        // ("Origin null is not allowed by Access-Control-Allow-Origin") and the
        // React app never mounts (blank panel). The Solid surface sidesteps this
        // by shipping a single inlined bundle; the shared React/Kanban surface is
        // code-split, so we must let file URLs read sibling files. KVC SPI,
        // consistent with the `drawsBackground` access just below.
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: KanbanBridgeContract.handlerName
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
        guard loadedRendererKind != rendererKind else { return }
        guard let webView, webView.window != nil else { return }
        guard let resourceDirectoryURL = Bundle.main.resourceURL else { return }
        let indexURL = Self.shellURL(
            rendererKind: rendererKind,
            resourceDirectoryURL: resourceDirectoryURL
        )
        trustedShellURL = Self.normalizedTrustedFileURL(indexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceDirectoryURL)
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
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        if let webView {
            webView.removeFromSuperview()
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: KanbanBridgeContract.handlerName,
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
                let request = try KanbanBridgeRequest(body: message.body)
                let reply = try await self.handle(request)
                replyHandler(["ok": true, "value": reply], nil)
            } catch let error as KanbanBridgeError {
                replyHandler(
                    ["ok": false, "error": ["code": error.code, "userMessage": error.localizedDescription]],
                    nil
                )
            } catch let error as KanbanEngineError {
                replyHandler(
                    ["ok": false, "error": ["code": "engine", "userMessage": Self.engineErrorMessage(error)]],
                    nil
                )
            } catch {
                replyHandler(["ok": false, "error": [:]], nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasFinishedNavigation = true
        applyThemeToLoadedPage()
        if isPanelFocused {
            focus()
        }
        flushInitialPaint(for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        _ = error
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        _ = error
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
        if Self.isTrustedShellURL(url, expected: trustedShellURL) {
            decisionHandler(.allow)
            return
        }
        if isInPageFragment(url, currentURL: webView.url) {
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
        webView.evaluateJavaScript("window.cmuxKanbanBridge?.applyTheme(\(json));") { _, _ in }
        sendEvent([
            "type": "app.theme",
            "theme": theme.dictionary
        ])
    }

    private func isTrustedBridgeFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame else { return false }
        return Self.isTrustedShellURL(frameInfo.request.url, expected: trustedShellURL)
    }

    nonisolated static func shellURL(
        rendererKind: KanbanRendererKind,
        resourceDirectoryURL: URL
    ) -> URL {
        rendererKind.resourceHTMLPathComponents.reduce(resourceDirectoryURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }

    nonisolated static func isTrustedShellURL(_ candidate: URL?, expected: URL?) -> Bool {
        guard let candidate = normalizedTrustedFileURL(candidate),
              let expected = normalizedTrustedFileURL(expected) else {
            return false
        }
        return candidate == expected
    }

    nonisolated static func normalizedTrustedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Bridge methods

    private func handle(_ request: KanbanBridgeRequest) async throws -> Any {
        switch request.method {
        case "app.context":
            return appContextPayload()
        case "getBoard":
            let board = try await startedEngine().currentBoard()
            return Self.boardPayload(board)
        case "createTask":
            let title = try request.requiredString("title")
            let detail = request.rawString("detail") ?? ""
            let backendKind = request.backendKind()
            let agentProvider = request.agentProvider()
            let board = try await startedEngine().createTask(
                title: title,
                detail: detail,
                backendKind: backendKind,
                agentProvider: agentProvider
            )
            return Self.boardPayload(board)
        case "moveCard":
            let cardId = try request.requiredUUID("cardId")
            let column = try request.requiredColumn()
            let board = try await startedEngine().moveCard(id: cardId, to: column)
            return Self.boardPayload(board)
        case "dispatchCard":
            let cardId = try request.requiredUUID("cardId")
            try await startedEngine().dispatch(cardId: cardId)
            return ["dispatched": true]
        case "cancelCard":
            let cardId = try request.requiredUUID("cardId")
            try await startedEngine().cancel(cardId: cardId)
            return ["cancelled": true]
        default:
            throw KanbanBridgeError.unsupportedMethod(request.method)
        }
    }

    /// Returns the engine, creating and subscribing to it on first use and
    /// running its one-time ``KanbanEngine/start()`` (load + orphan reconcile).
    private func startedEngine() async throws -> KanbanEngine {
        let engine = ensureEngine()
        if !didStartEngine {
            didStartEngine = true
            _ = try await engine.start()
        }
        return engine
    }

    private func ensureEngine() -> KanbanEngine {
        if let engine { return engine }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = CmuxStateDirectory.url(homeDirectory: home)
            .appendingPathComponent("kanban", isDirectory: true)
        let repository = KanbanBoardRepository(baseDirectory: base)
        let provisioner = GitWorktreeProvisioner(
            baseDirectory: base.appendingPathComponent("worktrees", isDirectory: true)
        )
        let backend = CmuxNativeBackend(workspaceRoot: workingDirectory, worktreeProvisioner: provisioner)
        let engine = KanbanEngine(workspaceId: workspaceId, repository: repository, backend: backend)
        self.engine = engine
        startSubscriptions(to: engine)
        return engine
    }

    /// Subscribes to the engine's board + progress streams and projects each
    /// onto the webview. The tasks are retained so ``close()`` can cancel them.
    private func startSubscriptions(to engine: KanbanEngine) {
        let boardTask = Task { [weak self] in
            for await board in engine.boardUpdates {
                guard let self else { break }
                self.sendEvent(["type": "kanban.boardUpdated", "board": Self.boardPayload(board)])
            }
        }
        let progressTask = Task { [weak self] in
            for await event in engine.progressEvents {
                guard let self else { break }
                self.sendEvent(Self.progressPayload(event))
            }
        }
        subscriptions = [boardTask, progressTask]
    }

    private func appContextPayload() -> [String: Any] {
        [
            "workspaceId": workspaceId.uuidString,
            "theme": theme.dictionary,
            "copy": Self.boardCopy()
        ]
    }

    nonisolated static func boardPayload(_ board: KanbanBoard) -> [String: Any] {
        // A fresh encoder per call: JSONEncoder is a reference type and is not
        // contractually safe to share across isolation domains. The `.iso8601`
        // strategy matches the repository so the wire shape equals the persisted
        // file (and the TypeScript `KanbanBoard` mirror).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(board),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    nonisolated static func boardCopy() -> [String: String] {
        [
            "boardTitle": String(localized: "kanban.web.boardTitle", defaultValue: "Board"),
            "columnBacklog": String(localized: "kanban.web.column.backlog", defaultValue: "Backlog"),
            "columnReady": String(localized: "kanban.web.column.ready", defaultValue: "Ready"),
            "columnBuilding": String(localized: "kanban.web.column.building", defaultValue: "Building"),
            "columnTesting": String(localized: "kanban.web.column.testing", defaultValue: "Testing"),
            "columnDone": String(localized: "kanban.web.column.done", defaultValue: "Done"),
            "columnBlocked": String(localized: "kanban.web.column.blocked", defaultValue: "Blocked"),
            "columnFailed": String(localized: "kanban.web.column.failed", defaultValue: "Failed"),
            "newTask": String(localized: "kanban.web.newTask", defaultValue: "New task"),
            "addTask": String(localized: "kanban.web.addTask", defaultValue: "Add"),
            "titlePlaceholder": String(localized: "kanban.web.titlePlaceholder", defaultValue: "Task title"),
            "detailPlaceholder": String(localized: "kanban.web.detailPlaceholder", defaultValue: "Details / spec (optional)"),
            "moveLeft": String(localized: "kanban.web.moveLeft", defaultValue: "Move left"),
            "moveRight": String(localized: "kanban.web.moveRight", defaultValue: "Move right"),
            "dispatch": String(localized: "kanban.web.dispatch", defaultValue: "Run"),
            "cancel": String(localized: "kanban.web.cancel", defaultValue: "Cancel"),
            "emptyColumn": String(localized: "kanban.web.emptyColumn", defaultValue: "No tasks"),
            "loading": String(localized: "kanban.web.loading", defaultValue: "Loading board…"),
            "requestFailed": String(localized: "kanban.web.requestFailed", defaultValue: "Board request failed.")
        ]
    }

    /// Maps a per-card dispatch event onto the `kanban.taskProgress` webview
    /// event. The board itself updates via `kanban.boardUpdated`; this carries
    /// the fine-grained run lifecycle (live output, session id, exit) for UI.
    nonisolated static func progressPayload(_ event: KanbanCardProgress) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "kanban.taskProgress",
            "cardId": event.cardId.uuidString
        ]
        switch event.progress {
        case .started(let sessionId):
            payload["kind"] = "started"
            payload["sessionId"] = sessionId
        case .provisioned(let worktreePath, let branchName):
            payload["kind"] = "provisioned"
            payload["worktreePath"] = worktreePath
            payload["branchName"] = branchName
        case .output(let text):
            payload["kind"] = "output"
            payload["text"] = text
        case .turnComplete:
            payload["kind"] = "turnComplete"
        case .exited(let status):
            payload["kind"] = "exited"
            payload["status"] = Int(status)
        case .failed(let message):
            payload["kind"] = "failed"
            payload["message"] = message
        }
        return payload
    }

    /// A localized, user-facing message for an engine-level failure.
    nonisolated static func engineErrorMessage(_ error: KanbanEngineError) -> String {
        switch error {
        case .unknownCard:
            return String(
                localized: "kanban.engine.error.unknownCard",
                defaultValue: "That task no longer exists."
            )
        case .wipLimitReached:
            return String(
                localized: "kanban.engine.error.wipLimitReached",
                defaultValue: "Too many tasks are already running. Finish or cancel one first."
            )
        }
    }

    private func handleExternalLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func sendEvent(_ event: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.cmuxKanbanBridge?.receive(\(json));") { _, _ in }
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
