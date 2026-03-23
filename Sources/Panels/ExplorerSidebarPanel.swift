import Foundation
import AppKit
import WebKit

/// Message handler for the sidebar file explorer WebView.
/// Self-contained file system handler that responds via `window.cmuxExplorer`.
final class ExplorerMessageHandler: NSObject, WKScriptMessageHandler {
    var rootPath: String = ""
    var onOpenFile: ((String) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "openFileExternal":
            guard let relativePath = body["path"] as? String else { return }
            let fullPath = (rootPath as NSString).appendingPathComponent(relativePath)
            DispatchQueue.main.async { [weak self] in
                self?.onOpenFile?(fullPath)
            }
        case "readDir":
            handleReadDir(body: body, webView: message.webView)
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
                items.append(["name": entry, "isDirectory": isDir.boolValue])
            }
            self.sendResponse(requestId: requestId, data: items, webView: webView)
        }
    }

    private func handleCreateFile(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            guard let fullPath = self.resolvedPath(relativePath, rootPath: rootPath) else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView); return
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: fullPath) {
                self.sendError(requestId: requestId, message: "File already exists", webView: webView); return
            }
            do {
                try fm.createDirectory(atPath: (fullPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard fm.createFile(atPath: fullPath, contents: nil) else {
                    self.sendError(requestId: requestId, message: "Failed to create file", webView: webView); return
                }
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch { self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView) }
        }
    }

    private func handleCreateDir(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            guard let fullPath = self.resolvedPath(relativePath, rootPath: rootPath) else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView); return
            }
            do {
                try FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch { self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView) }
        }
    }

    private func handleDeleteFile(body: [String: Any], webView: WKWebView?) {
        let relativePath = body["path"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""
        guard !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendError(requestId: requestId, message: "Cannot delete root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            guard let fullPath = self.resolvedPath(relativePath, rootPath: rootPath),
                  fullPath != URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView); return
            }
            do {
                try FileManager.default.removeItem(atPath: fullPath)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch { self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView) }
        }
    }

    private func handleRenameFile(body: [String: Any], webView: WKWebView?) {
        let oldRelPath = body["oldPath"] as? String ?? ""
        let newRelPath = body["newPath"] as? String ?? ""
        let requestId = body["requestId"] as? String ?? ""
        guard !oldRelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendError(requestId: requestId, message: "Cannot rename root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let canonicalRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
            guard let oldFull = self.resolvedPath(oldRelPath, rootPath: rootPath), oldFull != canonicalRoot,
                  let newFull = self.resolvedPath(newRelPath, rootPath: rootPath) else {
                self.sendError(requestId: requestId, message: "Invalid path", webView: webView); return
            }
            do {
                try FileManager.default.createDirectory(atPath: (newFull as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: oldFull, toPath: newFull)
                self.sendResponse(requestId: requestId, data: ["success": true], webView: webView)
            } catch { self.sendError(requestId: requestId, message: error.localizedDescription, webView: webView) }
        }
    }

    private func handleGitStatus(body: [String: Any], webView: WKWebView?) {
        let requestId = body["requestId"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [rootPath] in
            let statusProcess = Process()
            let statusPipe = Pipe()
            statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusProcess.arguments = ["-C", rootPath, "status", "--porcelain=v1", "-uall"]
            statusProcess.standardOutput = statusPipe
            statusProcess.standardError = FileHandle.nullDevice

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
                self.sendError(requestId: requestId, message: "git not available", webView: webView); return
            }

            let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
            let ignoredData = ignoredPipe.fileHandleForReading.readDataToEndOfFile()
            statusProcess.waitUntilExit()
            ignoredProcess.waitUntilExit()

            let statusOutput = String(data: statusData, encoding: .utf8) ?? ""
            let ignoredOutput = String(data: ignoredData, encoding: .utf8) ?? ""

            var files: [[String: String]] = []
            for line in statusOutput.components(separatedBy: "\n") where line.count >= 3 {
                let index = String(line[line.index(line.startIndex, offsetBy: 0)])
                let workTree = String(line[line.index(line.startIndex, offsetBy: 1)])
                var path = String(line[line.index(line.startIndex, offsetBy: 3)...])
                if path.contains(" -> ") { path = path.components(separatedBy: " -> ").last ?? path }

                let status: String
                if index == "?" && workTree == "?" { status = "untracked" }
                else if index == "!" && workTree == "!" { status = "ignored" }
                else if index == "U" || workTree == "U" || (index == "A" && workTree == "A") || (index == "D" && workTree == "D") { status = "conflict" }
                else if index == "A" || workTree == "A" { status = "added" }
                else if index == "D" || workTree == "D" { status = "deleted" }
                else if index == "R" { status = "renamed" }
                else { status = "modified" }

                files.append(["path": path, "status": status])
            }

            let ignoredFiles = ignoredOutput.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { ["path": $0, "status": "ignored"] as [String: String] }

            self.sendResponse(requestId: requestId, data: ["files": files, "ignored": ignoredFiles], webView: webView)
        }
    }

    // MARK: - Path Safety

    private func resolvedPath(_ relativePath: String, rootPath: String) -> String? {
        let candidate = relativePath.isEmpty ? rootPath : (rootPath as NSString).appendingPathComponent(relativePath)
        let canonical = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let canonicalRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        guard canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") else { return nil }
        return canonical
    }

    // MARK: - JS Communication (responses go to window.cmuxExplorer)

    private func sendResponse(requestId: String, data: Any, webView: WKWebView?) {
        guard let webView else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let js = "window.cmuxExplorer.handleResponse(\(Self.jsStringLiteral(requestId)), \(jsonString))"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func sendError(requestId: String, message: String, webView: WKWebView?) {
        guard let webView else { return }
        let js = "window.cmuxExplorer.handleError(\(Self.jsStringLiteral(requestId)), \(Self.jsStringLiteral(message)))"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayStr = String(data: data, encoding: .utf8),
              arrayStr.count > 2 else { return "\"\"" }
        let start = arrayStr.index(after: arrayStr.startIndex)
        let end = arrayStr.index(before: arrayStr.endIndex)
        return String(arrayStr[start..<end])
    }
}

// MARK: - Explorer Sidebar Panel

@MainActor
final class ExplorerSidebarPanel: ObservableObject {
    @Published var rootPath: String
    private(set) var webView: WKWebView
    private var messageHandler: ExplorerMessageHandler
    private var themeObserver: NSObjectProtocol?

    var onOpenFile: ((String) -> Void)? {
        didSet { messageHandler.onOpenFile = onOpenFile }
    }

    init(rootPath: String) {
        self.rootPath = rootPath

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let handler = ExplorerMessageHandler()
        handler.rootPath = rootPath
        config.userContentController.add(handler, name: "cmuxExplorer")
        self.messageHandler = handler

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        loadExplorerHTML()

        themeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.injectThemeColors() }
        }
    }

    deinit {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func updateRootPath(_ path: String) {
        guard path != rootPath else { return }
        rootPath = path
        messageHandler.rootPath = path
        loadExplorerHTML()
    }

    private func loadExplorerHTML() {
        guard let explorerURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "explorer"
        ) else { return }
        let explorerDir = explorerURL.deletingLastPathComponent()
        webView.navigationDelegate = themeInjector
        webView.loadFileURL(explorerURL, allowingReadAccessTo: explorerDir)
    }

    private lazy var themeInjector: ExplorerThemeInjector = {
        let injector = ExplorerThemeInjector()
        injector.panel = self
        return injector
    }()

    func injectThemeColors() {
        let bgColor = GhosttyBackgroundTheme.currentColor()
        let bgHex = bgColor.hexString()
        let isDark = bgColor.perceivedBrightness < 0.5

        let fg = isDark ? "#cccccc" : "#333333"
        let borderColor = isDark
            ? bgColor.adjustBrightness(by: 0.08).hexString()
            : bgColor.adjustBrightness(by: -0.08).hexString()
        let hoverBg = isDark
            ? bgColor.adjustBrightness(by: 0.06).hexString()
            : bgColor.adjustBrightness(by: -0.04).hexString()
        let selectedBg = isDark
            ? bgColor.adjustBrightness(by: 0.10).hexString()
            : bgColor.adjustBrightness(by: -0.08).hexString()
        let indentGuide = isDark
            ? bgColor.adjustBrightness(by: 0.20).hexString()
            : bgColor.adjustBrightness(by: -0.15).hexString()

        let js = "if (window.cmuxExplorer && window.cmuxExplorer.updateTheme) { window.cmuxExplorer.updateTheme('\(bgHex)', '\(fg)', '\(borderColor)', '\(hoverBg)', '\(selectedBg)', '\(indentGuide)'); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

final class ExplorerThemeInjector: NSObject, WKNavigationDelegate {
    weak var panel: ExplorerSidebarPanel?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in panel?.injectThemeColors() }
    }
}
