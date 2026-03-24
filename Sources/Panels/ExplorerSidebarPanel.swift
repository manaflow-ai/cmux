import Foundation
import AppKit
import WebKit

/// Message handler for the sidebar file explorer WebView.
/// Self-contained file system handler that responds via `window.cmuxExplorer`.
final class ExplorerMessageHandler: NSObject, WKScriptMessageHandler {
    var rootPaths: [String] = []
    var onOpenFile: ((String) -> Void)?
    var onPinFile: ((String) -> Void)?

    private func rootPath(for body: [String: Any]) -> String? {
        let index = body["rootIndex"] as? Int ?? 0
        guard index >= 0 && index < rootPaths.count else { return nil }
        return rootPaths[index]
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "pinFileExternal":
            guard let relativePath = body["path"] as? String,
                  let root = rootPath(for: body) else { return }
            let fullPath = (root as NSString).appendingPathComponent(relativePath)
            DispatchQueue.main.async { [weak self] in
                self?.onPinFile?(fullPath)
            }
        case "openFileExternal":
            guard let relativePath = body["path"] as? String,
                  let root = rootPath(for: body) else { return }
            let fullPath = (root as NSString).appendingPathComponent(relativePath)
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
        guard let rootPath = rootPath(for: body) else {
            sendError(requestId: requestId, message: "Invalid root", webView: webView); return
        }

        DispatchQueue.global(qos: .userInitiated).async {
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
                if entry == ".git" { continue }
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
        guard let rootPath = rootPath(for: body) else {
            sendError(requestId: requestId, message: "Invalid root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
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
        guard let rootPath = rootPath(for: body) else {
            sendError(requestId: requestId, message: "Invalid root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
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
        guard let rootPath = rootPath(for: body) else {
            sendError(requestId: requestId, message: "Invalid root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
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
        guard let rootPath = rootPath(for: body) else {
            sendError(requestId: requestId, message: "Invalid root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
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
        guard let rootPath = rootPath(for: body) else {
            sendError(requestId: requestId, message: "Invalid root", webView: webView); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // git status --porcelain -unormal: fast, doesn't recurse into untracked dirs
            let statusProcess = Process()
            let statusPipe = Pipe()
            statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusProcess.arguments = ["-C", rootPath, "status", "--porcelain=v1", "-unormal", "--ignored"]
            statusProcess.standardOutput = statusPipe
            statusProcess.standardError = FileHandle.nullDevice

            do { try statusProcess.run() }
            catch {
                self.sendError(requestId: requestId, message: "git not available", webView: webView); return
            }

            let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
            statusProcess.waitUntilExit()
            let statusOutput = String(data: statusData, encoding: .utf8) ?? ""

            var files: [[String: String]] = []
            var ignored: [[String: String]] = []

            for line in statusOutput.components(separatedBy: "\n") where line.count >= 3 {
                let index = String(line[line.index(line.startIndex, offsetBy: 0)])
                let workTree = String(line[line.index(line.startIndex, offsetBy: 1)])
                var path = String(line[line.index(line.startIndex, offsetBy: 3)...])
                // Strip trailing / from directory entries
                if path.hasSuffix("/") { path = String(path.dropLast()) }
                if path.contains(" -> ") { path = path.components(separatedBy: " -> ").last ?? path }

                if index == "!" && workTree == "!" {
                    ignored.append(["path": path, "status": "ignored"])
                    continue
                }

                let status: String
                if index == "?" && workTree == "?" { status = "untracked" }
                else if index == "U" || workTree == "U" || (index == "A" && workTree == "A") || (index == "D" && workTree == "D") { status = "conflict" }
                else if index == "A" || workTree == "A" { status = "added" }
                else if index == "D" || workTree == "D" { status = "deleted" }
                else if index == "R" { status = "renamed" }
                else { status = "modified" }

                files.append(["path": path, "status": status])
            }

            self.sendResponse(requestId: requestId, data: ["files": files, "ignored": ignored], webView: webView)
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
    @Published var rootPaths: [String]
    private(set) var webView: WKWebView
    private var messageHandler: ExplorerMessageHandler
    private var themeObserver: NSObjectProtocol?
    private var fsEventStream: FSEventStreamRef?
    fileprivate var hasLoaded = false

    var onOpenFile: ((String) -> Void)? {
        didSet { messageHandler.onOpenFile = onOpenFile }
    }

    var onPinFile: ((String) -> Void)? {
        didSet { messageHandler.onPinFile = onPinFile }
    }

    init(rootPaths: [String]) {
        self.rootPaths = rootPaths

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let handler = ExplorerMessageHandler()
        handler.rootPaths = rootPaths
        config.userContentController.add(handler, name: "cmuxExplorer")
        self.messageHandler = handler

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        loadExplorerHTML()
        startFSEvents()

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
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Update the root paths shown in the explorer. Only reloads JS if paths changed.
    func updateRootPaths(_ paths: [String]) {
        guard paths != rootPaths else { return }
        rootPaths = paths
        messageHandler.rootPaths = paths
        startFSEvents()
        if hasLoaded {
            sendRootsToJS()
        }
    }

    // MARK: - FSEvents File Watching

    private func startFSEvents() {
        stopFSEvents()
        guard !rootPaths.isEmpty else { return }

        let paths = rootPaths as CFArray
        var context = FSEventStreamContext()
        // Use Unmanaged to pass self as a pointer
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let panel = Unmanaged<ExplorerSidebarPanel>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                panel.handleFSEvent()
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, // 50ms latency
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopFSEvents() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    private func handleFSEvent() {
        let js = "if (window.cmuxExplorer && window.cmuxExplorer.refresh) { window.cmuxExplorer.refresh(); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
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

    /// Send the current root paths to the JS explorer so it can render them.
    func sendRootsToJS() {
        let rootsJSON = rootPaths.enumerated().map { index, path in
            let name = (path as NSString).lastPathComponent
            return "{\"name\":\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\",\"rootIndex\":\(index)}"
        }.joined(separator: ",")
        let js = "if (window.cmuxExplorer && window.cmuxExplorer.setRoots) { window.cmuxExplorer.setRoots([\(rootsJSON)]); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

final class ExplorerThemeInjector: NSObject, WKNavigationDelegate {
    weak var panel: ExplorerSidebarPanel?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            panel?.hasLoaded = true
            panel?.injectThemeColors()
            panel?.sendRootsToJS()
        }
    }
}
