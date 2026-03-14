import Foundation
import Combine
import AppKit
import WebKit

/// Message handler for JS -> Swift file system communication.
/// Handles readDir, readFile, writeFile, and dirtyState messages from the Monaco editor.
final class EditorMessageHandler: NSObject, WKScriptMessageHandler {
    var rootPath: String = ""
    var onDirtyStateChanged: ((Bool) -> Void)?
    var onActiveFileChanged: ((String?) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "readDir":
            handleReadDir(body: body, webView: message.webView)
        case "readFile":
            handleReadFile(body: body, webView: message.webView)
        case "writeFile":
            handleWriteFile(body: body, webView: message.webView)
        case "createFile":
            handleCreateFile(body: body, webView: message.webView)
        case "createDir":
            handleCreateDir(body: body, webView: message.webView)
        case "deleteFile":
            handleDeleteFile(body: body, webView: message.webView)
        case "renameFile":
            handleRenameFile(body: body, webView: message.webView)
        case "gitStatus":
            handleGitStatus(body: body, webView: message.webView)
        case "dirtyState":
            let dirty = body["isDirty"] as? Bool ?? false
            DispatchQueue.main.async { self.onDirtyStateChanged?(dirty) }
        case "activeFile":
            let fileName = body["fileName"] as? String
            DispatchQueue.main.async { self.onActiveFileChanged?(fileName) }
        default:
            break
        }
    }

    // MARK: - File Operations

    private func handleReadDir(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let fullPath = self.resolvedPath(relativePath, rootPath: rootPath)
            guard let fullPath else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }

            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: fullPath) else {
                self.sendError(requestId: requestId, message: "Cannot read directory", webView: webView)
                return
            }

            var items: [[String: Any]] = []
            for entry in entries.sorted() {
                if entry.hasPrefix(".") { continue }
                let entryPath = (fullPath as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: entryPath, isDirectory: &isDir)
                items.append([
                    "name": entry,
                    "isDirectory": isDir.boolValue
                ])
            }

            self.sendResponse(requestId: requestId, data: items, webView: webView)
        }
    }

    private func handleReadFile(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let fullPath = self.resolvedPath(relativePath, rootPath: rootPath)
            guard let fullPath else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }

            guard let data = FileManager.default.contents(atPath: fullPath),
                  let content = String(data: data, encoding: .utf8) else {
                self.sendError(requestId: requestId, message: "Cannot read file", webView: webView)
                return
            }

            self.sendResponse(requestId: requestId, data: ["content": content], webView: webView)
        }
    }

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

    private func handleCreateFile(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let fullPath = self.resolvedPath(relativePath, rootPath: rootPath)
            guard let fullPath else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }

            let fm = FileManager.default
            if fm.fileExists(atPath: fullPath) {
                self.sendError(requestId: requestId, message: "File already exists", webView: webView)
                return
            }

            // Create parent directories if needed
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                fm.createFile(atPath: fullPath, contents: nil)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch {
                self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView)
            }
        }
    }

    private func handleCreateDir(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let fullPath = self.resolvedPath(relativePath, rootPath: rootPath)
            guard let fullPath else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }

            do {
                try FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch {
                self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView)
            }
        }
    }

    private func handleDeleteFile(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let fullPath = self.resolvedPath(relativePath, rootPath: rootPath)
            guard let fullPath else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }
            do {
                try FileManager.default.removeItem(atPath: fullPath)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch {
                self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView)
            }
        }
    }

    private func handleRenameFile(body: [String: Any], webView: WKWebView?) {
        let oldRelPath = body["oldPath"] as? String ?? ""
        let newRelPath = body["newPath"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let oldFull = self.resolvedPath(oldRelPath, rootPath: rootPath)
            let newFull = self.resolvedPath(newRelPath, rootPath: rootPath)
            guard let oldFull, let newFull else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView)
                return
            }
            do {
                // Create parent directory if needed
                let parentDir = (newFull as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: oldFull, toPath: newFull)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch {
                self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView)
            }
        }
    }

    private func handleGitStatus(body: [String: Any], webView: WKWebView?) {
        let requestId = body["requestId"] as? String ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            // Run git status --porcelain=v1 -uall
            let statusProcess = Process()
            let statusPipe = Pipe()
            statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusProcess.arguments = ["-C", rootPath, "status", "--porcelain=v1", "-uall"]
            statusProcess.standardOutput = statusPipe
            statusProcess.standardError = FileHandle.nullDevice

            // Run git ls-files --others --ignored --exclude-standard
            let ignoredProcess = Process()
            let ignoredPipe = Pipe()
            ignoredProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            ignoredProcess.arguments = ["-C", rootPath, "ls-files", "--others", "--ignored", "--exclude-standard"]
            ignoredProcess.standardOutput = ignoredPipe
            ignoredProcess.standardError = FileHandle.nullDevice

            do {
                try statusProcess.run()
                try ignoredProcess.run()
            } catch {
                self.sendError(requestId: requestId, message: "git not available", webView: webView)
                return
            }

            // Read pipe data before waitUntilExit to prevent deadlock on large output
            let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
            let ignoredData = ignoredPipe.fileHandleForReading.readDataToEndOfFile()
            statusProcess.waitUntilExit()
            ignoredProcess.waitUntilExit()

            let statusOutput = String(data: statusData, encoding: .utf8) ?? ""
            let ignoredOutput = String(data: ignoredData, encoding: .utf8) ?? ""

            // Parse git status --porcelain output
            // Format: XY path (or XY oldpath -> newpath for renames)
            var files: [[String: String]] = []
            for line in statusOutput.components(separatedBy: "\n") where line.count >= 3 {
                let index = String(line[line.index(line.startIndex, offsetBy: 0)])
                let workTree = String(line[line.index(line.startIndex, offsetBy: 1)])
                var path = String(line[line.index(line.startIndex, offsetBy: 3)...])

                // Handle renames: "R  old -> new"
                if path.contains(" -> ") {
                    let parts = path.components(separatedBy: " -> ")
                    path = parts.last ?? path
                }

                // Determine effective status
                let status: String
                if index == "?" && workTree == "?" {
                    status = "untracked"
                } else if index == "!" && workTree == "!" {
                    status = "ignored"
                } else if index == "A" || workTree == "A" {
                    status = "added"
                } else if index == "D" || workTree == "D" {
                    status = "deleted"
                } else if index == "R" {
                    status = "renamed"
                } else if index == "U" || workTree == "U" ||
                          (index == "A" && workTree == "A") ||
                          (index == "D" && workTree == "D") {
                    status = "conflict"
                } else if index == "M" || workTree == "M" {
                    status = "modified"
                } else {
                    status = "modified"
                }

                files.append(["path": path, "status": status])
            }

            // Parse ignored files
            let ignoredFiles = ignoredOutput.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { ["path": $0, "status": "ignored"] as [String: String] }

            let result: [String: Any] = [
                "files": files,
                "ignored": ignoredFiles
            ]
            self.sendResponse(requestId: requestId, data: result, webView: webView)
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

        // Use JSON encoding for safe string transport
        guard let encodedPayload = try? JSONSerialization.data(withJSONObject: jsonString),
              let safePayload = String(data: encodedPayload, encoding: .utf8) else { return }

        let js = "window.cmux.handleResponse(\(Self.jsStringLiteral(requestId)), \(safePayload))"
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
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

/// A panel that embeds Monaco Editor in a WKWebView for file editing.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Root directory of the project being edited.
    let rootPath: String

    private(set) var workspaceId: UUID

    @Published private(set) var displayTitle: String = ""

    var displayIcon: String? { "doc.text.fill" }

    /// Whether any open file has unsaved changes (reported by Monaco via JS bridge).
    @Published var isDirty: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The underlying web view hosting Monaco Editor.
    private(set) var webView: CmuxWebView

    private var messageHandler: EditorMessageHandler?
    private var isClosed: Bool = false
    private var themeObserver: NSObjectProtocol?

    init(workspaceId: UUID, rootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rootPath = rootPath
        self.displayTitle = (rootPath as NSString).lastPathComponent

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

        handler.onDirtyStateChanged = { [weak self] dirty in
            self?.isDirty = dirty
        }
        handler.onActiveFileChanged = { [weak self] fileName in
            guard let self else { return }
            if let fileName {
                let baseName = (self.rootPath as NSString).lastPathComponent
                self.displayTitle = "\(baseName) — \(fileName)"
            } else {
                self.displayTitle = (self.rootPath as NSString).lastPathComponent
            }
        }

        loadEditorHTML()

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
        webView.navigationDelegate = themeInjector
        webView.loadFileURL(editorURL, allowingReadAccessTo: editorDir)
    }

    /// Lazily created navigation delegate that injects theme colors on page load.
    private lazy var themeInjector: EditorThemeInjector = {
        let injector = EditorThemeInjector()
        injector.panel = self
        return injector
    }()

    /// Inject current cmux/Ghostty theme colors into the editor CSS variables.
    func injectThemeColors() {
        let bgColor = GhosttyBackgroundTheme.currentColor()
        let bgHex = bgColor.hexString()

        // Derive related colors from the background
        let isDark = bgColor.perceivedBrightness < 0.5
        let sidebarBg = bgHex
        let editorBg = isDark
            ? bgColor.adjustBrightness(by: 0.03).hexString()
            : bgColor.adjustBrightness(by: -0.02).hexString()
        let borderColor = isDark
            ? bgColor.adjustBrightness(by: 0.08).hexString()
            : bgColor.adjustBrightness(by: -0.08).hexString()
        let hoverBg = isDark
            ? bgColor.adjustBrightness(by: 0.06).hexString()
            : bgColor.adjustBrightness(by: -0.04).hexString()
        let selectedBg = isDark
            ? bgColor.adjustBrightness(by: 0.10).hexString()
            : bgColor.adjustBrightness(by: -0.08).hexString()
        let fg = isDark ? "#cccccc" : "#333333"
        let fgSecondary = isDark ? "#969696" : "#666666"
        let indentGuide = isDark
            ? bgColor.adjustBrightness(by: 0.20).hexString()
            : bgColor.adjustBrightness(by: -0.15).hexString()

        let js = """
        (function() {
            var r = document.documentElement.style;
            r.setProperty('--sidebar-bg', '\(sidebarBg)');
            r.setProperty('--sidebar-fg', '\(fg)');
            r.setProperty('--sidebar-border', '\(borderColor)');
            r.setProperty('--sidebar-header-bg', '\(sidebarBg)');
            r.setProperty('--editor-bg', '\(editorBg)');
            r.setProperty('--editor-fg', '\(fg)');
            r.setProperty('--tab-bg', '\(sidebarBg)');
            r.setProperty('--tab-active-bg', '\(editorBg)');
            r.setProperty('--tab-border', '\(borderColor)');
            r.setProperty('--tab-inactive-fg', '\(fgSecondary)');
            r.setProperty('--tab-hover-bg', '\(hoverBg)');
            r.setProperty('--list-hover-bg', '\(hoverBg)');
            r.setProperty('--list-inactive-selection-bg', '\(selectedBg)');
            r.setProperty('--tree-indent-guide', '\(indentGuide)');
            r.setProperty('--input-bg', '\(hoverBg)');
            r.setProperty('--input-border', '\(borderColor)');
            r.setProperty('--input-fg', '\(fg)');
            r.setProperty('--context-menu-bg', '\(editorBg)');
            if (typeof window.cmux !== 'undefined' && typeof window.cmux.updateMonacoTheme === 'function') {
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

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}

// MARK: - Navigation delegate to inject theme on page load

final class EditorThemeInjector: NSObject, WKNavigationDelegate {
    weak var panel: EditorPanel?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            panel?.injectThemeColors()
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
