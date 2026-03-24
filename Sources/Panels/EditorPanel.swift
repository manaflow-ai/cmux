import Foundation
import Combine
import AppKit
import WebKit

/// Message handler for JS -> Swift communication.
/// Handles writeFile (save) and state notifications from the Monaco editor.
final class EditorMessageHandler: NSObject, WKScriptMessageHandler {
    var rootPath: String = ""
    var onDirtyStateChanged: ((Bool) -> Void)?
    var onActiveFileChanged: ((String?) -> Void)?
    var onEditorReady: (() -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "writeFile":
            handleWriteFile(body: body, webView: message.webView)
        case "dirtyState":
            let dirty = body["isDirty"] as? Bool ?? false
            DispatchQueue.main.async { self.onDirtyStateChanged?(dirty) }
        case "activeFile":
            let fileName = body["fileName"] as? String
            DispatchQueue.main.async { self.onActiveFileChanged?(fileName) }
        case "editorReady":
            DispatchQueue.main.async { self.onEditorReady?() }
        default:
            break
        }
    }

    // MARK: - File Operations

    private func handleWriteFile(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let content = body["content"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let fullPath = self.resolvedPath(relativePath, rootPath: rootPath)
            guard let fullPath else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }

            do {
                try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch {
                self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView)
            }
        }
    }

    // MARK: - Path Safety

    /// Resolve a relative path within rootPath, preventing directory traversal.
    private func resolvedPath(_ relativePath: String, rootPath: String) -> String? {
        let candidate: String
        if relativePath.isEmpty {
            candidate = rootPath
        } else {
            candidate = (rootPath as NSString).appendingPathComponent(relativePath)
        }

        // Canonicalize with symlink resolution to prevent traversal
        let canonical = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let canonicalRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path

        guard canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") else {
            return nil
        }
        return canonical
    }

    // MARK: - JS Communication

    private func sendResponse(requestId: String, data: Any, webView: WKWebView?) {
        guard let webView else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let js = "window.cmux.handleResponse(\(Self.jsStringLiteral(requestId)), \(jsonString))"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendError(requestId: String, message: String, webView: WKWebView?) {
        guard let webView else { return }
        let js = "window.cmux.handleError(\(Self.jsStringLiteral(requestId)), \(Self.jsStringLiteral(message)))"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Encode a Swift string as a safe JavaScript string literal using JSON serialization.
    private static func jsStringLiteral(_ value: String) -> String {
        // Wrap in array, serialize, then strip the [ ] brackets
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayStr = String(data: data, encoding: .utf8),
              arrayStr.count > 2 else {
            return "\"\""
        }
        // "[\"escaped string\"]" → "\"escaped string\""
        let start = arrayStr.index(after: arrayStr.startIndex)
        let end = arrayStr.index(before: arrayStr.endIndex)
        return String(arrayStr[start..<end])
    }
}

/// A panel that embeds Monaco Editor in a WKWebView for file editing.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Root directory used for path resolution.
    let rootPath: String

    /// The file to open (absolute path). Set at init or later via openFileByPath.
    private var pendingFilePath: String?

    private(set) var workspaceId: UUID

    @Published private(set) var displayTitle: String = ""

    var displayIcon: String? { "doc.text.fill" }

    /// Whether any open file has unsaved changes (reported by Monaco via JS bridge).
    @Published var isDirty: Bool = false

    /// Preview mode: single-click opens file here, double-click or edit pins it.
    /// When pinned (isPreview = false), new files open in a new panel instead.
    @Published var isPreview: Bool = true

    /// The currently open file's absolute path (for session persistence).
    private(set) var currentFilePath: String?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The underlying web view hosting Monaco Editor.
    private(set) var webView: CmuxWebView

    private var messageHandler: EditorMessageHandler?
    private var isClosed: Bool = false
    private var themeObserver: NSObjectProtocol?

    init(workspaceId: UUID, rootPath: String, filePath: String? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rootPath = rootPath
        self.pendingFilePath = filePath
        self.displayTitle = filePath.map { ($0 as NSString).lastPathComponent } ?? (rootPath as NSString).lastPathComponent

        // Try to grab a pre-warmed WebView from the pool for instant display
        if let pooled = MonacoWebViewPool.shared.take() {
            let handler = pooled.handler
            handler.rootPath = rootPath
            self.messageHandler = handler
            self.webView = pooled.webView as! CmuxWebView

            setupHandlerCallbacks(handler)

            // Monaco is already loaded — open the file immediately if we have one
            if let filePath = pendingFilePath {
                pendingFilePath = nil
                openFileByPath(filePath)
            }
        } else {
            // Fallback: create fresh WebView
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = true

            let handler = EditorMessageHandler()
            handler.rootPath = rootPath
            config.userContentController.add(handler, name: "cmuxEditor")
            self.messageHandler = handler

            let webView = CmuxWebView(frame: .zero, configuration: config)
            if #available(macOS 13.3, *) {
                webView.isInspectable = true
            }
            self.webView = webView

            setupHandlerCallbacks(handler)

            handler.onEditorReady = { [weak self] in
                guard let self, let filePath = self.pendingFilePath else { return }
                self.pendingFilePath = nil
                self.openFileByPath(filePath)
            }

            loadEditorHTML()
        }

        injectThemeColors()

        // Listen for theme changes
        themeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.injectThemeColors()
            }
        }
    }

    private func setupHandlerCallbacks(_ handler: EditorMessageHandler) {
        handler.onDirtyStateChanged = { [weak self] dirty in
            self?.isDirty = dirty
            if dirty { self?.isPreview = false }
        }
        handler.onActiveFileChanged = { [weak self] fileName in
            guard let self else { return }
            if let fileName {
                self.displayTitle = fileName
            } else {
                self.displayTitle = (self.rootPath as NSString).lastPathComponent
            }
        }
    }

    deinit {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func loadEditorHTML() {
        guard let editorURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "editor"
        ) else {
            return
        }
        let editorDir = editorURL.deletingLastPathComponent()

        // Pre-set the WebView background to match the theme before HTML loads
        let bgColor = GhosttyBackgroundTheme.currentColor()
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = bgColor.cgColor

        webView.navigationDelegate = themeInjector
        webView.loadFileURL(editorURL, allowingReadAccessTo: editorDir)
    }

    static let monacoVersion = "0.52.2"

    /// Inject Monaco CDN paths so the JS can load Monaco.
    func injectMonacoPaths() {
        let v = Self.monacoVersion
        let vsPath = "https://cdn.jsdelivr.net/npm/monaco-editor@\(v)/min/vs"
        let cssHref = "https://cdn.jsdelivr.net/npm/monaco-editor@\(v)/min/vs/editor/editor.main.css"
        let js = "window.cmux.initMonaco('\(vsPath)', '\(cssHref)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Lazily created navigation delegate that injects theme colors on page load.
    private lazy var themeInjector: EditorThemeInjector = {
        let injector = EditorThemeInjector()
        injector.panel = self
        return injector
    }()

    /// Inject current cmux/Ghostty theme colors into the editor.
    func injectThemeColors() {
        let bgColor = GhosttyBackgroundTheme.currentColor()
        let isDark = bgColor.perceivedBrightness < 0.5
        let editorBg = isDark
            ? bgColor.adjustBrightness(by: 0.03).hexString()
            : bgColor.adjustBrightness(by: -0.02).hexString()
        let fg = isDark ? "#cccccc" : "#333333"

        let js = """
        (function() {
            document.documentElement.style.setProperty('--editor-bg', '\(editorBg)');
            document.body.style.background = '\(editorBg)';
            if (window.cmux && typeof window.cmux.updateMonacoTheme === 'function') {
                window.cmux.updateMonacoTheme('\(editorBg)', '\(fg)');
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func focus() {
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window else { return }
        if window.firstResponder === webView {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        isClosed = true
        unfocus()
        webView.stopLoading()
        if messageHandler != nil {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxEditor")
        }
        messageHandler = nil
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason = .notificationArrival) {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    /// Open a specific file by its absolute path in the Monaco editor.
    /// The path is converted to a relative path within the editor's root.
    func openFileByPath(_ absolutePath: String) {
        currentFilePath = absolutePath
        let relativePath: String
        if absolutePath.hasPrefix(rootPath + "/") {
            relativePath = String(absolutePath.dropFirst(rootPath.count + 1))
        } else {
            relativePath = (absolutePath as NSString).lastPathComponent
        }
        let fileName = (relativePath as NSString).lastPathComponent
        let fm = FileManager.default

        // Check size — stat is fast (~0.1ms)
        if let attrs = try? fm.attributesOfItem(atPath: absolutePath),
           let size = attrs[.size] as? Int, size > 1_048_576 {
            let sizeMB = String(format: "%.1f", Double(size) / 1_048_576)
            displayTitle = fileName
            let js = "if (window.cmux && window.cmux.showLargeFile) { window.cmux.showLargeFile('\(jsEscape(fileName))', '\(sizeMB) MB — file is too large to open in the editor'); }"
            webView.evaluateJavaScript(js, completionHandler: nil)
            return
        }

        // Read file synchronously — source files are small, this is <1ms
        guard let data = fm.contents(atPath: absolutePath),
              let content = String(data: data, encoding: .utf8) else { return }

        if content.count > 5_000_000 {
            displayTitle = fileName
            let js = "if (window.cmux && window.cmux.showLargeFile) { window.cmux.showLargeFile('\(jsEscape(fileName))', 'file is too large to open in the editor'); }"
            webView.evaluateJavaScript(js, completionHandler: nil)
            return
        }

        // Encode content as JSON string for safe JS injection
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [content]),
              let jsonArray = String(data: jsonData, encoding: .utf8),
              jsonArray.count > 2 else { return }
        let jsonString = String(jsonArray[jsonArray.index(after: jsonArray.startIndex)..<jsonArray.index(before: jsonArray.endIndex)])

        let js = "if (window.cmux && window.cmux.openFileWithContent) { window.cmux.openFileWithContent('\(jsEscape(relativePath))', '\(jsEscape(fileName))', \(jsonString)); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// MARK: - Navigation delegate to inject theme on page load

final class EditorThemeInjector: NSObject, WKNavigationDelegate {
    weak var panel: EditorPanel?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            panel?.injectThemeColors()
            panel?.injectMonacoPaths()
        }
    }
}

// MARK: - NSColor helpers

extension NSColor {
    var perceivedBrightness: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0.5 }
        return rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
    }

    func adjustBrightness(by amount: CGFloat) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        return NSColor(
            red: max(0, min(1, rgb.redComponent + amount)),
            green: max(0, min(1, rgb.greenComponent + amount)),
            blue: max(0, min(1, rgb.blueComponent + amount)),
            alpha: rgb.alphaComponent
        )
    }
}
