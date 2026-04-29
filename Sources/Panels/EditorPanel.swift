import Foundation
import Combine
import WebKit

/// An editable code editor panel that displays syntax-highlighted file content
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

    /// Whether the current file has unsaved edits.
    @Published private(set) var isDirty: Bool = false

    /// Last save or navigation error shown in the editor header.
    @Published private(set) var lastSaveErrorMessage: String?

    /// Last content loaded from or saved to disk.
    private var lastLoadedContent: String = ""

    // MARK: - WKWebView

    /// The WKWebView hosting Monaco Editor.
    private(set) var webView: CmuxWebView?
    private var hasLoadedMonacoPage = false
    private var pendingGoToLine: (line: Int, column: Int?)?

    /// Message handler name for JS → Swift bridge.
    static let bridgeHandlerName = "cmuxEditor"

    // MARK: - Send to terminal

    /// Target terminal panel ID for the next send-selection round-trip.
    private(set) var pendingReturnTerminalPanelId: UUID?

    // MARK: - File watching

    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var directoryWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var directoryDescriptor: Int32 = -1
    private var pendingExternalReloadTask: Task<Void, Never>?
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
        // No-op for editor panel.
    }

    func close() {
        isClosed = true
        stopFileWatcher()
        pendingExternalReloadTask?.cancel()
        pendingExternalReloadTask = nil
        if let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeHandlerName)
            wv.removeFromSuperview()
            webView = nil
        }
        hasLoadedMonacoPage = false
        isMonacoReady = false
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    // MARK: - Public API

    /// Inferred Monaco language identifier from file extension.
    var monacoLanguage: String {
        guard !filePath.isEmpty else { return "plaintext" }
        return Self.monacoLanguageFromExtension((filePath as NSString).pathExtension)
    }

    /// Navigate to a different file path.
    @discardableResult
    func navigateToFile(_ newPath: String) -> Bool {
        let currentCanonical = (filePath as NSString).resolvingSymlinksInPath
        let newCanonical = (newPath as NSString).resolvingSymlinksInPath
        if !filePath.isEmpty, currentCanonical == newCanonical {
            return true
        }

        guard !isDirty else {
            lastSaveErrorMessage = String(localized: "editor.unsavedSwitchBlocked", defaultValue: "Save changes before opening another file.")
            return false
        }

        stopFileWatcher()
        filePath = newPath
        displayTitle = (newPath as NSString).lastPathComponent
        isDiffMode = false
        diffBaseContent = nil
        diffBaseLabel = nil
        isDirty = false
        lastSaveErrorMessage = nil
        lastLoadedContent = ""
        pendingGoToLine = nil
        loadFileContent()
        startFileWatcher()
        return true
    }

    /// Ensure this editor keeps a workspace file explorer rooted at `rootDirectory`.
    func ensureWorkspaceFileExplorer(rootDirectory: String) {
        let trimmedRoot = rootDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else { return }

        let canonicalRoot = (trimmedRoot as NSString).resolvingSymlinksInPath
        if let existingRoot = workspaceRootDirectory,
           (existingRoot as NSString).resolvingSymlinksInPath == canonicalRoot {
            return
        }

        workspaceRootDirectory = trimmedRoot
        fileExplorerStore.setProvider(LocalFileExplorerProvider())
        fileExplorerStore.showHiddenFiles = fileExplorerState.showHiddenFiles
        fileExplorerStore.setRootPath(trimmedRoot)
    }

    /// Enter diff mode comparing the current file against base content.
    func enterDiffMode(baseContent: String, baseLabel: String?) {
        isDirty = false
        lastSaveErrorMessage = nil
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
        applyPendingGoToLineIfNeeded()
    }

    // MARK: - WKWebView setup

    /// Create and configure the WKWebView for Monaco Editor.
    func createWebView() -> CmuxWebView {
        if let webView {
            return webView
        }

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
        guard !hasLoadedMonacoPage else { return }
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
        hasLoadedMonacoPage = true
        wv.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
    }

    /// Push current file content to Monaco (called when Monaco is ready or content changes).
    func pushContentToMonaco() {
        guard !isWorkspaceRootPlaceholder else { return }
        guard isMonacoReady, let wv = webView, !isFileUnavailable else { return }

        if isDiffMode, let baseContent = diffBaseContent {
            let escapedOriginal = Self.jsEscapeString(baseContent)
            let escapedModified = Self.jsEscapeString(content)
            let lang = Self.jsEscapeString(monacoLanguage)
            wv.evaluateJavaScript(
                "cmuxEditor.setDiffContent(\(escapedOriginal), \(escapedModified), \(lang))"
            )
        } else {
            let escaped = Self.jsEscapeString(content)
            let lang = Self.jsEscapeString(monacoLanguage)
            let escapedPath = Self.jsEscapeString(filePath)
            wv.evaluateJavaScript(
                "cmuxEditor.setContent(\(escaped), \(lang), \(escapedPath))"
            )
        }
    }

    /// Go to a specific line in Monaco.
    func goToLine(_ line: Int, column: Int? = nil) {
        let targetLine = max(1, line)
        let targetColumn = column.map { max(1, $0) }
        pendingGoToLine = (targetLine, targetColumn)
        applyPendingGoToLineIfNeeded()
    }

    private func applyPendingGoToLineIfNeeded() {
        guard let target = pendingGoToLine,
              isMonacoReady,
              let wv = webView else { return }
        pendingGoToLine = nil
        let col = target.column ?? 1
        wv.evaluateJavaScript("cmuxEditor.goToLine(\(target.line), \(col))")
    }

    /// Show Monaco's in-file find widget.
    func triggerFind() {
        guard isMonacoReady, let wv = webView else { return }
        wv.evaluateJavaScript("cmuxEditor.triggerFind()")
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

    /// Save the current Monaco content to disk.
    func save() {
        guard !filePath.isEmpty, !isDiffMode else { return }
        getContent { [weak self] currentContent in
            guard let self else { return }
            guard let currentContent else {
                self.lastSaveErrorMessage = String(localized: "editor.readContentFailed", defaultValue: "Could not read editor content.")
                return
            }
            self.writeContentToDisk(currentContent)
        }
    }

    private func writeContentToDisk(_ newContent: String) {
        do {
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
            content = newContent
            lastLoadedContent = newContent
            isFileUnavailable = false
            isDirty = false
            lastSaveErrorMessage = nil
            if fileWatchSource == nil {
                startFileWatcher()
            }
        } catch {
            lastSaveErrorMessage = String(localized: "editor.saveFailed", defaultValue: "Could not save file.")
        }
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
        case .contentChanged:
            guard !isWorkspaceRootPlaceholder, !isDiffMode else { return }
            isDirty = true
            lastSaveErrorMessage = nil
        case .saveRequested:
            save()
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
        guard JSONSerialization.isValidJSONObject([str]),
              let data = try? JSONSerialization.data(withJSONObject: [str], options: []),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.hasPrefix("["),
              arrayLiteral.hasSuffix("]") else {
            return "\"\""
        }
        return String(arrayLiteral.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - File I/O

    private func loadFileContent() {
        guard !filePath.isEmpty else { return }
        guard !isDirty else { return }

        let newContent: String
        do {
            newContent = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                newContent = decoded
            } else {
                isFileUnavailable = true
                return
            }
        }

        if !isFileUnavailable, newContent == content {
            lastLoadedContent = newContent
            lastSaveErrorMessage = nil
            return
        }

        content = newContent
        lastLoadedContent = newContent
        isFileUnavailable = false
        lastSaveErrorMessage = nil
        pushContentToMonaco()
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        guard !filePath.isEmpty else { return }

        if fileWatchSource == nil {
            let fd = open(filePath, O_EVTONLY)
            if fd >= 0 {
                fileDescriptor = fd

                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename, .extend, .attrib],
                    queue: watchQueue
                )

                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    let flags = source.data
                    Task { @MainActor in
                        self.handleFileSystemEvent(flags, shouldReattach: flags.contains(.delete) || flags.contains(.rename))
                    }
                }

                source.setCancelHandler {
                    Darwin.close(fd)
                }

                source.resume()
                fileWatchSource = source
            }
        }

        if directoryWatchSource == nil {
            let directoryPath = (filePath as NSString).deletingLastPathComponent
            let fd = open(directoryPath, O_EVTONLY)
            guard fd >= 0 else { return }
            directoryDescriptor = fd

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: watchQueue
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.handleFileSystemEvent(source.data, shouldReattach: true)
                }
            }

            source.setCancelHandler {
                Darwin.close(fd)
            }

            source.resume()
            directoryWatchSource = source
        }
    }

    private func handleFileSystemEvent(_ flags: DispatchSource.FileSystemEvent, shouldReattach: Bool) {
        guard !isClosed else { return }
        let reattach = shouldReattach || flags.contains(.delete) || flags.contains(.rename)
        scheduleExternalFileReload(reattachWatcher: reattach)
    }

    private func scheduleExternalFileReload(reattachWatcher: Bool) {
        pendingExternalReloadTask?.cancel()
        pendingExternalReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            if reattachWatcher {
                self.stopFileWatcher(cancelPendingReload: false)
            }
            self.loadFileContent()
            if self.isFileUnavailable {
                self.scheduleReattach(attempt: 1)
            } else {
                self.startFileWatcher()
            }
        }
    }

    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
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

    private func stopFileWatcher(cancelPendingReload: Bool = true) {
        if cancelPendingReload {
            pendingExternalReloadTask?.cancel()
            pendingExternalReloadTask = nil
        }
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
        if let source = directoryWatchSource {
            source.cancel()
            directoryWatchSource = nil
        }
        directoryDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
        directoryWatchSource?.cancel()
        pendingExternalReloadTask?.cancel()
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
    case contentChanged
    case saveRequested
    case sendSelection(content: String)

    init?(body: [String: Any]) {
        guard let type = body["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "selectionChanged":
            guard let hasSelection = body["hasSelection"] as? Bool else { return nil }
            self = .selectionChanged(hasSelection: hasSelection)
        case "contentChanged":
            self = .contentChanged
        case "saveRequested":
            self = .saveRequested
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
        case .contentChanged:
            cmuxDebugLog("editor.bridge type=contentChanged")
        case .saveRequested:
            cmuxDebugLog("editor.bridge type=saveRequested")
        case .sendSelection(let content):
            cmuxDebugLog("editor.bridge type=sendSelection len=\(content.count)")
        }
        #endif
        Task { @MainActor in
            onMessage(bridgeMessage)
        }
    }
}
