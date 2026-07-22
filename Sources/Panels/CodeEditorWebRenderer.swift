import AppKit
import SwiftUI
import WebKit

/// Serves the bundled editor surface (`Resources/markdown-viewer/webviews-app/`)
/// over `cmux-editor://bundle/…`.
///
/// A custom scheme is required instead of `loadFileURL`: the "Compress
/// Markdown Viewer Assets" build phase replaces every bundled `.js`/`.mjs`
/// with a `.deflate` sibling, so plain file URLs to module scripts 404 in
/// built apps. This handler resolves the plain file first and falls back to
/// inflating the `.deflate` variant via `DiffViewerAssetReader` (WebKit does
/// not honor Content-Encoding on app-owned schemes).
final class CodeEditorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-editor"
    static let shellURL = URL(string: "\(scheme)://bundle/editor.html")!

    private static let mimeTypesByExtension: [String: String] = [
        "html": "text/html",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "css": "text/css",
        "json": "application/json",
        "map": "application/json",
        "svg": "image/svg+xml",
        "wasm": "application/wasm",
        "woff2": "font/woff2"
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // ponytail: synchronous serving on the main thread; assets are small
        // bundled chunks loaded only when an editor panel opens. Move to a
        // background queue if editor open ever shows up in a profile.
        guard let url = urlSchemeTask.request.url,
              let data = Self.assetData(for: url) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }
        let mimeType = Self.mimeTypesByExtension[url.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func assetData(for url: URL) -> Data? {
        guard url.scheme == scheme,
              let resourceDirectoryURL = Bundle.main.resourceURL else {
            return nil
        }
        let baseURL = resourceDirectoryURL
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .standardizedFileURL
        let relativePath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relativePath.isEmpty else { return nil }
        let candidate = baseURL.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(baseURL.path + "/") else { return nil }

        let fileManager = FileManager.default
        let fileURL: URL
        if fileManager.fileExists(atPath: candidate.path) {
            fileURL = candidate
        } else if fileManager.fileExists(atPath: candidate.path + ".deflate") {
            fileURL = URL(fileURLWithPath: candidate.path + ".deflate")
        } else {
            return nil
        }

        guard let reader = try? DiffViewerAssetReader(fileURL: fileURL) else { return nil }
        defer { try? reader.close() }
        var data = Data()
        while let chunk = try? reader.read(upToCount: 512 * 1024), !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }
}

/// WKWebView hosting the CodeMirror editor surface. Mirrors
/// `AgentSessionWebView`: pointer-down requests panel focus instead of the
/// webview grabbing it implicitly.
@MainActor
final class CodeEditorWebView: WKWebView {
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
final class CodeEditorWebHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onDidMoveToWindow?()
        }
    }

    func attachWebView(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

/// Panel-owned retention for the code editor webview, so the editor (and its
/// undo history) survives SwiftUI view recreation during split/pane moves.
/// Registered in `FilePreviewNativeViewSessions`.
@MainActor
final class CodeEditorWebSession {
    private(set) var coordinator: CodeEditorWebCoordinator?

    func ensureCoordinator() -> CodeEditorWebCoordinator {
        if let coordinator {
            return coordinator
        }
        let coordinator = CodeEditorWebCoordinator()
        self.coordinator = coordinator
        return coordinator
    }

    func close() {
        guard let coordinator else { return }
        self.coordinator = nil
        coordinator.closeSalvagingDirtyBuffer()
    }
}

/// Bridge + lifecycle for the CodeMirror editor surface
/// (`webviews/src/surfaces/editorSurface.ts`, handler name `cmuxEditor`).
///
/// Ownership contract: the webview owns the live buffer; Swift owns file IO
/// through `FilePreviewPanel` (load, save, watch). Saves initiated natively
/// (header button, save shortcut) pull the buffer via
/// `window.cmuxEditorHost.getContent()`; saves initiated in JS (Cmd+S inside
/// the editor) arrive as `editor.save` bridge calls. Both converge on
/// `FilePreviewPanel.saveResolvedTextContent`.
@MainActor
final class CodeEditorWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private static let bridgeHandlerName = "cmuxEditor"

    private(set) var webView: CodeEditorWebView?
    private weak var panel: FilePreviewPanel?
    private var theme: AgentSessionWebTheme?
    private var wordWrap = false
    private var isPanelFocused = false
    private var hasLoadedShell = false
    private var isReady = false
    /// Last content both sides agreed is on disk; used to drop file-watcher
    /// echoes of our own saves instead of resetting the JS buffer.
    private var lastSyncedDiskContent: String?
    private var lastDiskSyncToken: Int?

    func bind(panel: FilePreviewPanel, theme: AgentSessionWebTheme, wordWrap: Bool, isFocused: Bool) {
        self.panel = panel
        panel.setWebEditorSaveHandler({ [weak self] in
            self?.saveFromHost()
        }, owner: self)
        isPanelFocused = isFocused
        if self.theme != theme {
            self.theme = theme
            if isReady {
                sendEvent(["type": "app.theme", "theme": theme.dictionary])
            }
        }
        if self.wordWrap != wordWrap {
            self.wordWrap = wordWrap
            if isReady {
                sendEvent(["type": "app.options", "wordWrap": wordWrap])
            }
        }
        syncDiskContentIfNeeded()
    }

    func ensureWebView(onPointerDown: @escaping () -> Void) -> CodeEditorWebView {
        if let webView {
            webView.onPointerDown = onPointerDown
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.setURLSchemeHandler(
            CodeEditorAssetSchemeHandler(),
            forURLScheme: CodeEditorAssetSchemeHandler.scheme
        )
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: Self.bridgeHandlerName
        )
        let webView = CodeEditorWebView(frame: .zero, configuration: configuration)
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
        panel?.attachPreviewFocus(root: webView, primaryResponder: webView, intent: .textEditor)
        return webView
    }

    func loadShellIfNeeded() {
        guard !hasLoadedShell else { return }
        guard let webView, webView.window != nil else { return }
        webView.load(URLRequest(url: CodeEditorAssetSchemeHandler.shellURL))
        hasLoadedShell = true
    }

    func focus() {
        guard let webView else { return }
        _ = webView.window?.makeFirstResponder(webView)
    }

    /// Tears down after copying an unsaved JS buffer back into the panel, so
    /// switching `fileEditor.engine` mid-edit hands dirty content to the
    /// plain editor instead of dropping it.
    func closeSalvagingDirtyBuffer() {
        guard let panel, panel.isDirty, isReady, webView != nil else {
            close()
            return
        }
        Task { @MainActor [weak panel] in
            if let content = await self.pullContent() {
                panel?.updateTextContent(content)
            }
            self.close()
        }
    }

    func close() {
        // Ownership-guarded: this close may run from an async dirty-buffer
        // salvage after a replacement coordinator has already bound.
        panel?.clearWebEditorSaveHandler(ifOwnedBy: self)
        if let webView {
            webView.removeFromSuperview()
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: Self.bridgeHandlerName,
                contentWorld: .page
            )
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.onPointerDown = nil
        }
        webView = nil
        panel = nil
        hasLoadedShell = false
        isReady = false
        lastSyncedDiskContent = nil
        lastDiskSyncToken = nil
    }

    // MARK: - Bridge

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard isTrustedBridgeFrame(message.frameInfo),
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(["ok": false, "error": [:]], nil)
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]
        Task { @MainActor in
            if let value = await self.handle(method: method, params: params) {
                replyHandler(["ok": true, "value": value], nil)
            } else {
                replyHandler(["ok": false, "error": [:]], nil)
            }
        }
    }

    private func handle(method: String, params: [String: Any]) async -> Any? {
        guard let panel else { return nil }
        switch method {
        case "editor.ready":
            isReady = true
            lastDiskSyncToken = panel.textDiskSyncToken
            lastSyncedDiskContent = panel.diskTextContent
            return [
                "content": panel.textContent,
                "diskContent": panel.diskTextContent,
                "path": panel.filePath,
                "wordWrap": wordWrap,
                "locale": Bundle.main.preferredLocalizations.first ?? "en",
                "theme": theme?.dictionary ?? [:],
                "copy": [
                    "fileChangedOnDisk": String(
                        localized: "codeEditor.fileChangedOnDisk",
                        defaultValue: "File changed on disk"
                    ),
                    "reloadFromDisk": String(
                        localized: "codeEditor.reloadFromDisk",
                        defaultValue: "Reload"
                    ),
                    "keepMyChanges": String(
                        localized: "codeEditor.keepMyChanges",
                        defaultValue: "Keep my changes"
                    ),
                    "saveFailed": String(
                        localized: "codeEditor.saveFailed",
                        defaultValue: "Could not save the file."
                    )
                ]
            ] as [String: Any]
        case "editor.dirtyChanged":
            guard let isDirty = params["isDirty"] as? Bool else { return nil }
            panel.webEditorDidChangeDirty(isDirty)
            return ["accepted": true]
        case "editor.save":
            guard let content = params["content"] as? String else { return nil }
            let saved = await panel.saveResolvedTextContent(content)
            if saved {
                lastSyncedDiskContent = content
            }
            return ["saved": saved]
        default:
            return nil
        }
    }

    /// Native save entry point (header button / save shortcut): pulls the live
    /// buffer from JS, writes it, then tells JS its baseline moved.
    private func saveFromHost() -> Task<Void, Never>? {
        guard isReady, webView != nil else { return nil }
        return Task { @MainActor [weak self] in
            guard let self, let content = await self.pullContent() else { return }
            guard let panel = self.panel else { return }
            let saved = await panel.saveResolvedTextContent(content)
            if saved {
                self.lastSyncedDiskContent = content
                self.sendEvent(["type": "document.saved", "content": content])
            }
        }
    }

    private func pullContent() async -> String? {
        guard let webView else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.cmuxEditorHost ? window.cmuxEditorHost.getContent() : null;",
            arguments: [:],
            contentWorld: .page
        )
        return result as? String
    }

    private func syncDiskContentIfNeeded() {
        guard isReady, let panel else { return }
        guard lastDiskSyncToken != panel.textDiskSyncToken else { return }
        lastDiskSyncToken = panel.textDiskSyncToken
        let diskContent = panel.diskTextContent
        guard diskContent != lastSyncedDiskContent else { return }
        lastSyncedDiskContent = diskContent
        sendEvent(["type": "document.external", "content": diskContent])
    }

    private func sendEvent(_ event: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.cmuxEditorBridge?.receive(\(json));") { _, error in
#if DEBUG
            if let error {
                cmuxDebugLog("codeEditor.bridge.event.failed error=\(error.localizedDescription)")
            }
#else
            _ = error
#endif
        }
    }

    private func isTrustedBridgeFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame else { return false }
        return frameInfo.request.url?.scheme == CodeEditorAssetSchemeHandler.scheme
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isPanelFocused {
            focus()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.request.url?.scheme == CodeEditorAssetSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

/// Hosts the CodeMirror editor webview inside a FilePreview panel's text mode
/// when `fileEditor.engine` is `"code"`.
struct CodeEditorWebRenderer: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let isFocused: Bool
    let theme: AgentSessionWebTheme
    let wordWrap: Bool
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> CodeEditorWebCoordinator {
        panel.nativeViewSessions.codeEditorWeb.ensureCoordinator()
    }

    func makeNSView(context: Context) -> CodeEditorWebHostView {
        let host = CodeEditorWebHostView()
        host.wantsLayer = true
        return host
    }

    func updateNSView(_ host: CodeEditorWebHostView, context: Context) {
        let coordinator = context.coordinator
        host.isHidden = !isVisibleInUI
        coordinator.bind(panel: panel, theme: theme, wordWrap: wordWrap, isFocused: isFocused)
        let webView = coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        applyBackground(to: host)
        applyBackground(to: webView)
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak coordinator] in
            coordinator?.loadShellIfNeeded()
        }
        coordinator.loadShellIfNeeded()
        if isFocused {
            coordinator.focus()
        }
    }

    static func dismantleNSView(_ nsView: CodeEditorWebHostView, coordinator: CodeEditorWebCoordinator) {
        nsView.onDidMoveToWindow = nil
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
}
