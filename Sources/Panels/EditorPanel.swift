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

    // MARK: - Path Safety

    /// Resolve a relative path within rootPath, preventing directory traversal.
    private func resolvedPath(_ relativePath: String, rootPath: String) -> String? {
        let candidate: String
        if relativePath.isEmpty {
            candidate = rootPath
        } else {
            candidate = (rootPath as NSString).appendingPathComponent(relativePath)
        }

        // Canonicalize to resolve symlinks and ".." components
        let canonical = (candidate as NSString).standardizingPath
        let canonicalRoot = (rootPath as NSString).standardizingPath

        guard canonical.hasPrefix(canonicalRoot) else {
            return nil
        }
        return canonical
    }

    // MARK: - JS Communication

    private func sendResponse(requestId: String, data: Any, webView: WKWebView?) {
        guard let webView else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let escaped = jsonString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let js = "window.cmux.handleResponse('\(requestId)', '\(escaped)')"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendError(requestId: String, message: String, webView: WKWebView?) {
        guard let webView else { return }
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "window.cmux.handleError('\(requestId)', '\(escaped)')"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
        webView.loadFileURL(editorURL, allowingReadAccessTo: editorDir)
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
