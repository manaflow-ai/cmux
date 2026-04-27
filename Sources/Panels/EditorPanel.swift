import Foundation
import Combine
import WebKit

/// A read-only code viewer panel that displays syntax-highlighted file content
/// using Monaco Editor in a WKWebView, with live file-watching.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being displayed.
    @Published private(set) var filePath: String

    /// Workspace directory shown before a file is selected.
    @Published private(set) var workspaceRootDirectory: String?

    /// Whether this panel is waiting for a file selection from the workspace.
    var isWorkspaceRootPlaceholder: Bool {
        workspaceRootDirectory != nil && filePath.isEmpty
    }

    /// Whether this panel should keep showing the embedded workspace file explorer.
    var hasWorkspaceFileExplorer: Bool {
        workspaceRootDirectory != nil
    }

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current file content read from disk.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Embedded file explorer used by workspace-root placeholder editors.
    let fileExplorerStore = FileExplorerStore()
    let fileExplorerState = FileExplorerState()

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Whether the panel is in diff mode.
    @Published private(set) var isDiffMode: Bool = false

    /// The base content for diff comparison (e.g., from git HEAD).
    @Published private(set) var diffBaseContent: String?

    /// Label for the diff base (e.g., "HEAD").
    @Published private(set) var diffBaseLabel: String?

    /// Whether Monaco has finished loading and is ready for commands.
    @Published private(set) var isMonacoReady: Bool = false

    /// Whether there is a non-empty text selection in Monaco.
    @Published private(set) var hasSelection: Bool = false

    // MARK: - WKWebView

    /// The WKWebView hosting Monaco Editor.
    private(set) var webView: CmuxWebView?

    /// Message handler name for JS → Swift bridge.
    static let bridgeHandlerName = "cmuxEditor"

    // MARK: - Send to terminal

    /// Target terminal panel ID for the next send-selection round-trip.
    private(set) var pendingReturnTerminalPanelId: UUID?

    // MARK: - File watching

    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.editor-file-watch", qos: .utility)

    private static let maxReattachAttempts = 6
    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.workspaceRootDirectory = nil
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            scheduleReattach(attempt: 1)
        }
    }

    init(workspaceId: UUID, workspaceRootDirectory: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = ""
        self.workspaceRootDirectory = workspaceRootDirectory
        self.displayTitle = String(localized: "editor.workspace.title", defaultValue: "Editor")

        fileExplorerStore.setProvider(LocalFileExplorerProvider())
        fileExplorerStore.showHiddenFiles = fileExplorerState.showHiddenFiles
        fileExplorerStore.setRootPath(workspaceRootDirectory)
    }

    // MARK: - Panel protocol

    func focus() {
        // WKWebView focus is managed by EditorPanelView.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        stopFileWatcher()
        if let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeHandlerName)
            wv.removeFromSuperview()
            webView = nil
        }
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Public API

    /// Inferred Monaco language identifier from file extension.
    var monacoLanguage: String {
        guard !filePath.isEmpty else { return "plaintext" }
        return Self.monacoLanguageFromExtension((filePath as NSString).pathExtension)
    }

    /// Navigate to a different file path.
    func navigateToFile(_ newPath: String) {
        stopFileWatcher()
        filePath = newPath
        displayTitle = (newPath as NSString).lastPathComponent
        isDiffMode = false
        diffBaseContent = nil
        diffBaseLabel = nil
        loadFileContent()
        startFileWatcher()
    }

    /// Enter diff mode comparing the current file against base content.
    func enterDiffMode(baseContent: String, baseLabel: String?) {
        isDiffMode = true
        diffBaseContent = baseContent
        diffBaseLabel = baseLabel
        pushContentToMonaco()
    }

    /// Exit diff mode and return to normal view.
    func exitDiffMode() {
        isDiffMode = false
        diffBaseContent = nil
        diffBaseLabel = nil
        pushContentToMonaco()
    }

    /// Arm a send-selection round-trip targeting the given terminal panel.
    func armSendSelection(returnTo terminalPanelId: UUID) {
        pendingReturnTerminalPanelId = terminalPanelId
    }

    /// Clear any pending send-selection round-trip.
    func clearSendSelection() {
        pendingReturnTerminalPanelId = nil
    }

    /// Called by the JS bridge when Monaco reports selection state.
    func updateSelectionState(hasSelection: Bool) {
        self.hasSelection = hasSelection
    }

    /// Called by the JS bridge when Monaco finishes loading.
    func markMonacoReady() {
        isMonacoReady = true
        pushContentToMonaco()
    }

    // MARK: - WKWebView setup

    /// Create and configure the WKWebView for Monaco Editor.
    func createWebView() -> CmuxWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let handler = EditorBridgeMessageHandler { [weak self] message in
            self?.handleBridgeMessage(message)
        }
        config.userContentController.add(handler, name: Self.bridgeHandlerName)

        let wv = CmuxWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        wv.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        self.webView = wv
        return wv
    }

    /// Load the Monaco HTML page from the app bundle.
    func loadMonacoPage() {
        guard let wv = webView else { return }
        guard let htmlURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "editor-monaco"
        ) else {
            #if DEBUG
            cmuxDebugLog("editor.loadMonacoPage: index.html not found in bundle")
            #endif
            return
        }
        let resourceDir = htmlURL.deletingLastPathComponent()
        wv.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
    }

    /// Push current file content to Monaco (called when Monaco is ready or content changes).
    func pushContentToMonaco() {
        guard !isWorkspaceRootPlaceholder else { return }
        guard isMonacoReady, let wv = webView, !isFileUnavailable else { return }

        if isDiffMode, let baseContent = diffBaseContent {
            let escapedOriginal = Self.jsEscapeString(baseContent)
            let escapedModified = Self.jsEscapeString(content)
            let lang = monacoLanguage
            wv.evaluateJavaScript(
                "cmuxEditor.setDiffContent(\"\(escapedOriginal)\", \"\(escapedModified)\", \"\(lang)\")"
            )
        } else {
            let escaped = Self.jsEscapeString(content)
            let lang = monacoLanguage
            let escapedPath = Self.jsEscapeString(filePath)
            wv.evaluateJavaScript(
                "cmuxEditor.setContent(\"\(escaped)\", \"\(lang)\", \"\(escapedPath)\")"
            )
        }
    }

    /// Go to a specific line in Monaco.
    func goToLine(_ line: Int, column: Int? = nil) {
        guard isMonacoReady, let wv = webView else { return }
        let col = column ?? 1
        wv.evaluateJavaScript("cmuxEditor.goToLine(\(line), \(col))")
    }

    /// Get the full content from Monaco via callback.
    func getContent(completion: @escaping (String?) -> Void) {
        guard isMonacoReady, let wv = webView else {
            completion(content)
            return
        }
        wv.evaluateJavaScript("cmuxEditor.getContent()") { result, _ in
            completion(result as? String)
        }
    }

    /// Get current selection from Monaco.
    func getSelection(completion: @escaping (String?) -> Void) {
        guard isMonacoReady, let wv = webView else {
            completion(nil)
            return
        }
        wv.evaluateJavaScript("cmuxEditor.getSelection()") { result, _ in
            completion(result as? String)
        }
    }

    /// Trigger the send-selection flow from Swift.
    func triggerSendSelection() {
        guard isMonacoReady, let wv = webView else { return }
        wv.evaluateJavaScript("cmuxEditor.triggerSendSelection()")
    }

    /// Set Monaco theme from Swift.
    func setTheme(isDark: Bool) {
        guard isMonacoReady, let wv = webView else { return }
        wv.evaluateJavaScript("cmuxEditor.setTheme(\(isDark))")
    }

    // MARK: - Bridge message handling

    private func handleBridgeMessage(_ message: EditorBridgeMessage) {
        switch message {
        case .ready:
            markMonacoReady()
        case .selectionChanged(let has):
            updateSelectionState(hasSelection: has)
        case .sendSelection(let text):
            guard let returnPanelId = pendingReturnTerminalPanelId else { return }
            clearSendSelection()
            NotificationCenter.default.post(
                name: .editorDidSendSelection,
                object: nil,
                userInfo: [
                    EditorSendSelectionNotificationKey.workspaceId: workspaceId,
                    EditorSendSelectionNotificationKey.editorPanelId: id,
                    EditorSendSelectionNotificationKey.returnPanelId: returnPanelId,
                    EditorSendSelectionNotificationKey.content: text,
                ]
            )
        }
    }

    // MARK: - JS string escaping

    private static func jsEscapeString(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count + str.count / 10)
        for ch in str {
            switch ch {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(ch)
            }
        }
        return result
    }

    // MARK: - File I/O

    private func loadFileContent() {
        guard !filePath.isEmpty else { return }
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            isFileUnavailable = false
        } catch {
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
        pushContentToMonaco()
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        guard !filePath.isEmpty else { return }
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    self.loadFileContent()
                    if self.isFileUnavailable {
                        self.scheduleReattach(attempt: 1)
                    } else {
                        self.startFileWatcher()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.loadFileContent()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.isFileUnavailable = false
                    self.loadFileContent()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
    }

    // MARK: - Language detection

    private static func monacoLanguageFromExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascript"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "typescript"
        case "py", "pyw": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "cs": return "csharp"
        case "m", "mm": return "objective-c"
        case "json", "jsonc": return "json"
        case "xml", "plist", "svg": return "xml"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "md", "markdown": return "markdown"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh": return "shell"
        case "fish": return "shell"
        case "sql": return "sql"
        case "dockerfile": return "dockerfile"
        case "r": return "r"
        case "lua": return "lua"
        case "php": return "php"
        case "pl", "pm": return "perl"
        case "zig": return "zig"
        case "dart": return "dart"
        case "scala": return "scala"
        case "ex", "exs": return "elixir"
        case "erl", "hrl": return "erlang"
        case "hs": return "haskell"
        case "clj", "cljs": return "clojure"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "tf", "tfvars": return "hcl"
        case "ini", "cfg": return "ini"
        case "bat", "cmd": return "bat"
        case "ps1", "psm1": return "powershell"
        case "vue": return "html"
        case "svelte": return "html"
        default: return "plaintext"
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let editorDidSendSelection = Notification.Name("cmux.editorDidSendSelection")
    static let fileExplorerOpenInCodeViewer = Notification.Name("cmux.fileExplorerOpenInCodeViewer")
}

enum EditorSendSelectionNotificationKey {
    static let workspaceId = "workspaceId"
    static let editorPanelId = "editorPanelId"
    static let returnPanelId = "returnPanelId"
    static let content = "content"
}

// MARK: - Bridge message types

enum EditorBridgeMessage {
    case ready
    case selectionChanged(hasSelection: Bool)
    case sendSelection(content: String)

    init?(body: [String: Any]) {
        guard let type = body["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "selectionChanged":
            guard let hasSelection = body["hasSelection"] as? Bool else { return nil }
            self = .selectionChanged(hasSelection: hasSelection)
        case "sendSelection":
            guard let content = body["content"] as? String else { return nil }
            self = .sendSelection(content: content)
        default:
            return nil
        }
    }
}

// MARK: - WKScriptMessageHandler

class EditorBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (EditorBridgeMessage) -> Void

    init(onMessage: @escaping @MainActor (EditorBridgeMessage) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let bridgeMessage = EditorBridgeMessage(body: body) else { return }
        #if DEBUG
        switch bridgeMessage {
        case .ready:
            cmuxDebugLog("editor.bridge type=ready")
        case .selectionChanged(let has):
            cmuxDebugLog("editor.bridge type=selectionChanged hasSelection=\(has)")
        case .sendSelection(let content):
            cmuxDebugLog("editor.bridge type=sendSelection len=\(content.count)")
        }
        #endif
        Task { @MainActor in
            onMessage(bridgeMessage)
        }
    }
}
