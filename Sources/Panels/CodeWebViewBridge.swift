import Foundation
import WebKit

struct CodeStaticBootstrap {
    @MainActor
    static func currentUserScript() -> WKUserScript? {
        guard let source = scriptSource(theme: .current()) else { return nil }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    static func scriptSource(theme: CodeWebThemeSnapshot) -> String? {
        let payload: [String: Any] = [
            "isDark": theme.isDark,
            "variables": theme.variables,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return """
        (() => {
          if (window.location.protocol !== "\(CodeStaticURLSchemeHandler.scheme):") return;
          const theme = \(json);
          const root = document.documentElement;
          if (!root) return;
          root.dataset.cmuxGhosttyTheme = "true";
          root.classList.toggle("dark", theme.isDark);
          root.style.colorScheme = theme.isDark ? "dark" : "light";
          for (const [name, value] of Object.entries(theme.variables)) {
            root.style.setProperty(name, value);
          }
        })()
        """
    }
}

private enum CodeWebViewBridgeError: Error {
    case invalidRequest
    case requestTooLarge
    case responseTooLarge
    case unavailable
}

final class CodeStaticURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-code"
    static let host = "app"
    static let launcherURL = URL(string: "\(scheme)://\(host)/index.html")
    static let shared = CodeStaticURLSchemeHandler()

    private final class TaskState: @unchecked Sendable {
        let condition = NSCondition()
        var callbacksInFlight = 0
        var isStopped = false
    }

    private let lock = NSLock()
    private let streamQueue = DispatchQueue(
        label: "com.manaflow.cmux.code-static-assets",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var activeTasks: [ObjectIdentifier: TaskState] = [:]

    static func isTrustedURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == scheme
            && url.host == host
            && url.user == nil
            && url.password == nil
            && url.port == nil
    }

    static func resolvedFileURL(
        for requestURL: URL,
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard isTrustedURL(requestURL) else { return nil }
        let rawPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let relativePath = rawPath == "/" || rawPath.isEmpty
            ? "index.html"
            : String(rawPath.drop(while: { $0 == "/" }))
        guard !relativePath.isEmpty,
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            return nil
        }

        let trustedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = trustedRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(trustedRoot.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let resourceRoot = Bundle.main.resourceURL?
                  .appendingPathComponent("code-sidecar/client", isDirectory: true),
              let fileURL = Self.resolvedFileURL(for: requestURL, rootURL: resourceRoot) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
            )
            return
        }

        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let state = TaskState()
        lock.lock()
        activeTasks[taskID] = state
        lock.unlock()

        streamQueue.async { [weak self] in
            guard let self else { return }
            do {
                let body = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                let mimeType = Self.mimeType(for: fileURL.pathExtension)
                let cacheControl = fileURL.lastPathComponent == "index.html"
                    ? "no-cache"
                    : "public, max-age=31536000, immutable"
                let headers = [
                    "Cache-Control": cacheControl,
                    "Content-Length": String(body.count),
                    "Content-Type": mimeType,
                    "Cross-Origin-Resource-Policy": "same-origin",
                    "X-Content-Type-Options": "nosniff",
                ]
                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) ?? URLResponse(
                    url: requestURL,
                    mimeType: mimeType,
                    expectedContentLength: body.count,
                    textEncodingName: Self.textEncodingName(for: fileURL.pathExtension)
                )

                guard self.performCallback(taskID, { urlSchemeTask.didReceive(response) }) else {
                    return
                }
                guard self.performCallback(taskID, { urlSchemeTask.didReceive(body) }) else {
                    return
                }
                guard self.performCallback(taskID, { urlSchemeTask.didFinish() }) else {
                    return
                }
                self.stopTask(taskID)
            } catch {
                _ = self.performCallback(taskID, { urlSchemeTask.didFailWithError(error) })
                self.stopTask(taskID)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopTask(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func performCallback(_ taskID: ObjectIdentifier, _ callback: () -> Void) -> Bool {
        lock.lock()
        let state = activeTasks[taskID]
        lock.unlock()
        guard let state else { return false }

        state.condition.lock()
        guard !state.isStopped else {
            state.condition.unlock()
            return false
        }
        state.callbacksInFlight += 1
        state.condition.unlock()

        callback()

        state.condition.lock()
        state.callbacksInFlight -= 1
        if state.callbacksInFlight == 0 {
            state.condition.broadcast()
        }
        let remainsActive = !state.isStopped
        state.condition.unlock()
        return remainsActive
    }

    private func stopTask(_ taskID: ObjectIdentifier) {
        lock.lock()
        let state = activeTasks.removeValue(forKey: taskID)
        lock.unlock()
        guard let state else { return }

        state.condition.lock()
        state.isStopped = true
        while state.callbacksInFlight > 0 {
            state.condition.wait()
        }
        state.condition.unlock()
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "css": "text/css; charset=utf-8"
        case "html": "text/html; charset=utf-8"
        case "ico": "image/x-icon"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    private static func textEncodingName(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "css", "html", "js", "json", "mjs", "svg": "utf-8"
        default: nil
        }
    }
}

private struct CodeBridgeFetchRequest {
    static let maximumBodyBytes = 32 * 1024 * 1024

    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?

    init(body object: [String: Any]) throws {
        guard let rawURL = object["url"] as? String,
              let url = URL(string: rawURL),
              url.scheme == "https",
              url.host == "cmux-code.invalid",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let method = object["method"] as? String,
              !method.isEmpty,
              method.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0)
              }) else {
            throw CodeWebViewBridgeError.invalidRequest
        }
        self.url = url
        self.method = method

        let rawHeaders = object["headers"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        for (name, value) in rawHeaders {
            guard let value = value as? String,
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n") else {
                throw CodeWebViewBridgeError.invalidRequest
            }
            headers[name] = value
        }
        self.headers = headers

        if let encodedBody = object["bodyBase64"] as? String {
            guard let decoded = Data(base64Encoded: encodedBody),
                  decoded.count <= Self.maximumBodyBytes else {
                throw CodeWebViewBridgeError.requestTooLarge
            }
            body = decoded
        } else {
            body = nil
        }
    }

    func urlRequest(connection: CodeSidecarConnection) throws -> URLRequest {
        guard var components = URLComponents(url: connection.httpBaseURL, resolvingAgainstBaseURL: false) else {
            throw CodeWebViewBridgeError.unavailable
        }
        components.percentEncodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath ?? url.path
        components.percentEncodedQuery = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedQuery
        guard let localURL = components.url else {
            throw CodeWebViewBridgeError.invalidRequest
        }

        var request = URLRequest(url: localURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        let blockedHeaders = Set([
            "accept-encoding",
            "authorization",
            "connection",
            "content-length",
            "cookie",
            "host",
            "origin",
            "proxy-authorization",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        ])
        for (name, value) in headers where !blockedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

@MainActor
final class CodeSurfaceMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "cmuxCode"
    private static let maximumResponseBytes = 64 * 1024 * 1024

    private weak var panel: BrowserPanel?
    private weak var webView: CmuxWebView?
    private let surfaceID: UUID
    private let workingDirectory: String?
    private var sockets: [String: CodeWebSocketConnection] = [:]
    private var openingSocketIDs = Set<String>()
    private var cancelledSocketIDs = Set<String>()
    private var isClosed = false
    private var didSignalReady = false
    private let fetchSession: URLSession

    init(
        surfaceID: UUID,
        workingDirectory: String?,
        webView: CmuxWebView,
        panel: BrowserPanel? = nil
    ) {
        self.surfaceID = surfaceID
        self.workingDirectory = workingDirectory
        self.webView = webView
        self.panel = panel
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        fetchSession = URLSession(configuration: configuration)
    }

    static func install(
        on webView: CmuxWebView,
        surfaceID: UUID,
        workingDirectory: String?,
        panel: BrowserPanel? = nil
    ) -> CodeSurfaceMessageHandler {
        let handler = CodeSurfaceMessageHandler(
            surfaceID: surfaceID,
            workingDirectory: workingDirectory,
            webView: webView,
            panel: panel
        )
        let userContentController = webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(forName: name, contentWorld: .page)
        userContentController.addScriptMessageHandler(
            handler,
            contentWorld: .page,
            name: name
        )
        webView.codeSurfaceMessageHandler = handler
        return handler
    }

    func adopt(panel: BrowserPanel, webView: CmuxWebView) {
        guard !isClosed, self.webView === webView else { return }
        self.panel = panel
    }

    deinit {
        fetchSession.invalidateAndCancel()
    }

    func closeAll() {
        guard !isClosed else { return }
        isClosed = true
        cancelledSocketIDs.formUnion(openingSocketIDs)
        openingSocketIDs.removeAll()
        let openSockets = sockets.values
        sockets.removeAll()
        for socket in openSockets {
            socket.close(code: 1001, reason: "Surface closed")
        }
        CodeSidecarService.shared.release(surfaceID: surfaceID)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              CodeStaticURLSchemeHandler.isTrustedURL(message.frameInfo.request.url),
              message.webView === webView,
              let body = message.body as? [String: Any],
              JSONSerialization.isValidJSONObject(body),
              let type = body["type"] as? String,
              !isClosed else {
            replyHandler(nil, "Code bridge request rejected")
            return
        }

        switch type {
        case "mount":
            mount(replyHandler: replyHandler)
        case "fetch":
            fetch(body: body, replyHandler: replyHandler)
        case "websocketOpen":
            openSocket(body: body, replyHandler: replyHandler)
        case "websocketSend":
            sendSocket(body: body, replyHandler: replyHandler)
        case "websocketClose":
            closeSocket(body: body, replyHandler: replyHandler)
        case "ready":
            signalReady(replyHandler: replyHandler)
        case "unready":
            signalUnready(replyHandler: replyHandler)
        default:
            replyHandler(nil, "Unknown Code bridge request")
        }
    }

    private func mount(replyHandler: @escaping (Any?, String?) -> Void) {
        Task { [weak self] in
            guard let self, !self.isClosed else {
                replyHandler(nil, "Code surface closed")
                return
            }
            do {
                _ = try await CodeSidecarService.shared.mount(
                    surfaceID: self.surfaceID,
                    workingDirectory: self.workingDirectory
                )
                replyHandler(["ok": true], nil)
            } catch is CancellationError {
                replyHandler(nil, "Code surface closed")
            } catch {
                self.panel?.renderCodeSidecarLaunchError()
                self.webView?.onCodeSurfaceFailed?()
                replyHandler(nil, "Code service unavailable")
            }
        }
    }

    private func fetch(
        body: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { [weak self] in
            guard let self, !self.isClosed else {
                replyHandler(nil, "Code surface closed")
                return
            }
            do {
                guard let requestObject = body["request"] as? [String: Any] else {
                    throw CodeWebViewBridgeError.invalidRequest
                }
                let bridgedRequest = try CodeBridgeFetchRequest(body: requestObject)
                let connection = try await CodeSidecarService.shared.mount(
                    surfaceID: self.surfaceID,
                    workingDirectory: self.workingDirectory
                )
                let request = try bridgedRequest.urlRequest(connection: connection)
                let (data, response) = try await self.fetchSession.data(for: request)
                guard data.count <= Self.maximumResponseBytes,
                      let response = response as? HTTPURLResponse else {
                    throw data.count > Self.maximumResponseBytes
                        ? CodeWebViewBridgeError.responseTooLarge
                        : CodeWebViewBridgeError.unavailable
                }
                var headers: [String: String] = [:]
                for (rawName, rawValue) in response.allHeaderFields {
                    let name = String(describing: rawName)
                    let lowercased = name.lowercased()
                    guard lowercased != "content-encoding",
                          lowercased != "content-length",
                          lowercased != "set-cookie" else { continue }
                    headers[name] = String(describing: rawValue)
                }
                replyHandler([
                    "bodyBase64": data.base64EncodedString(),
                    "headers": headers,
                    "status": response.statusCode,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                ], nil)
            } catch is CancellationError {
                replyHandler(nil, "Code request cancelled")
            } catch {
                replyHandler(nil, "Code request failed")
            }
        }
    }

    private func openSocket(
        body: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let socketID = body["id"] as? String,
              UUID(uuidString: socketID) != nil,
              let rawURL = body["url"] as? String,
              let pseudoURL = URL(string: rawURL),
              pseudoURL.scheme == "wss",
              pseudoURL.host == "cmux-code.invalid",
              pseudoURL.user == nil,
              pseudoURL.password == nil,
              pseudoURL.port == nil else {
            replyHandler(nil, "Invalid Code socket request")
            return
        }
        let protocols = (body["protocols"] as? [String]) ?? []
        guard !openingSocketIDs.contains(socketID) else {
            replyHandler(nil, "Code socket is already opening")
            return
        }
        cancelledSocketIDs.remove(socketID)
        openingSocketIDs.insert(socketID)

        Task { [weak self] in
            guard let self, !self.isClosed else {
                replyHandler(nil, "Code surface closed")
                return
            }
            do {
                let connection = try await CodeSidecarService.shared.mount(
                    surfaceID: self.surfaceID,
                    workingDirectory: self.workingDirectory
                )
                self.openingSocketIDs.remove(socketID)
                guard self.cancelledSocketIDs.remove(socketID) == nil else {
                    replyHandler(nil, "Code socket cancelled")
                    return
                }
                let request = try Self.webSocketRequest(
                    pseudoURL: pseudoURL,
                    protocols: protocols,
                    connection: connection
                )
                let socket = CodeWebSocketConnection(
                    socketID: socketID,
                    request: request,
                    owner: self
                )
                self.sockets[socketID]?.close(code: 1001, reason: "Socket replaced")
                self.sockets[socketID] = socket
                socket.start()
                replyHandler(["ok": true], nil)
            } catch {
                self.openingSocketIDs.remove(socketID)
                replyHandler(nil, "Code socket failed")
            }
        }
    }

    private func sendSocket(
        body: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let socketID = body["id"] as? String,
              let socket = sockets[socketID],
              let kind = body["kind"] as? String,
              let payload = body["payload"] as? String else {
            replyHandler(nil, "Code socket is unavailable")
            return
        }
        Task {
            do {
                switch kind {
                case "text":
                    try await socket.send(.string(payload))
                case "binary":
                    guard let data = Data(base64Encoded: payload),
                          data.count <= CodeBridgeFetchRequest.maximumBodyBytes else {
                        throw CodeWebViewBridgeError.requestTooLarge
                    }
                    try await socket.send(.data(data))
                default:
                    throw CodeWebViewBridgeError.invalidRequest
                }
                replyHandler(["ok": true], nil)
            } catch {
                replyHandler(nil, "Code socket send failed")
            }
        }
    }

    private func closeSocket(
        body: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let socketID = body["id"] as? String else {
            replyHandler(nil, "Invalid Code socket request")
            return
        }
        let socket = sockets.removeValue(forKey: socketID)
        if openingSocketIDs.contains(socketID) {
            cancelledSocketIDs.insert(socketID)
        }
        let code = body["code"] as? Int ?? 1000
        let reason = body["reason"] as? String ?? ""
        socket?.close(code: code, reason: reason)
        replyHandler(["ok": true], nil)
    }

    private func signalReady(replyHandler: @escaping (Any?, String?) -> Void) {
        guard !sockets.isEmpty else {
            replyHandler(nil, "Code connection is not ready")
            return
        }
        if !didSignalReady {
            didSignalReady = true
            webView?.onCodeSurfaceReady?()
        }
        replyHandler(["ok": true], nil)
    }

    private func signalUnready(replyHandler: @escaping (Any?, String?) -> Void) {
        if didSignalReady {
            didSignalReady = false
            webView?.onCodeSurfaceUnready?()
        }
        replyHandler(["ok": true], nil)
    }

    fileprivate func socketOpened(id: String, protocol selectedProtocol: String?) {
        emitSocketEvent([
            "id": id,
            "protocol": selectedProtocol ?? "",
            "type": "open",
        ])
    }

    fileprivate func socketReceived(id: String, message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            emitSocketEvent(["id": id, "kind": "text", "payload": text, "type": "message"])
        case .data(let data):
            emitSocketEvent([
                "id": id,
                "kind": "binary",
                "payload": data.base64EncodedString(),
                "type": "message",
            ])
        @unknown default:
            socketFailed(id: id)
        }
    }

    fileprivate func socketFailed(id: String) {
        guard let socket = sockets.removeValue(forKey: id) else { return }
        socket.finish()
        emitSocketEvent(["id": id, "type": "error"])
        emitSocketEvent(["code": 1006, "id": id, "reason": "", "type": "close", "wasClean": false])
    }

    fileprivate func socketClosed(id: String, code: Int, reason: String) {
        guard let socket = sockets.removeValue(forKey: id) else { return }
        socket.finish()
        emitSocketEvent([
            "code": code,
            "id": id,
            "reason": reason,
            "type": "close",
            "wasClean": code == 1000 || code == 1001,
        ])
    }

    private func emitSocketEvent(_ event: [String: Any]) {
        guard let webView,
              CodeStaticURLSchemeHandler.isTrustedURL(webView.url),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.cmuxCode?.__receiveSocketEvent(\(json));",
            completionHandler: nil
        )
    }

    private static func webSocketRequest(
        pseudoURL: URL,
        protocols: [String],
        connection: CodeSidecarConnection
    ) throws -> URLRequest {
        guard var components = URLComponents(url: connection.httpBaseURL, resolvingAgainstBaseURL: false) else {
            throw CodeWebViewBridgeError.unavailable
        }
        components.scheme = "ws"
        let pseudoComponents = URLComponents(url: pseudoURL, resolvingAgainstBaseURL: false)
        components.percentEncodedPath = pseudoComponents?.percentEncodedPath ?? pseudoURL.path
        components.percentEncodedQuery = pseudoComponents?.percentEncodedQuery
        guard let localURL = components.url else {
            throw CodeWebViewBridgeError.invalidRequest
        }
        var request = URLRequest(url: localURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return request
    }
}

@MainActor
private final class CodeWebSocketConnection: NSObject, URLSessionWebSocketDelegate {
    nonisolated let socketID: String
    private weak var owner: CodeSurfaceMessageHandler?
    private let request: URLRequest
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(socketID: String, request: URLRequest, owner: CodeSurfaceMessageHandler) {
        self.socketID = socketID
        self.request = request
        self.owner = owner
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receiveNext()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let task else { throw CodeWebViewBridgeError.unavailable }
        try await task.send(message)
    }

    func close(code: Int, reason: String) {
        receiveTask?.cancel()
        receiveTask = nil
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.isEmpty ? nil : Data(reason.utf8))
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func finish() {
        receiveTask?.cancel()
        receiveTask = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveNext() {
        guard receiveTask == nil, let task else { return }
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let message = try await task.receive()
                self.receiveTask = nil
                self.owner?.socketReceived(id: self.socketID, message: message)
                self.receiveNext()
            } catch is CancellationError {
                self.receiveTask = nil
            } catch {
                self.receiveTask = nil
                self.owner?.socketFailed(id: self.socketID)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.socketOpened(id: self.socketID, protocol: `protocol`)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.socketClosed(
                id: self.socketID,
                code: closeCode.rawValue,
                reason: reasonString
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.socketFailed(id: self.socketID)
        }
    }
}
