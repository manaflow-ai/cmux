import Foundation
import Combine
import Security
#if canImport(Hummingbird)
import Hummingbird
#endif

struct RemoteAccessSettings {
    static let enabledKey = "remoteAccessEnabled"
    static let portKey = "remoteAccessPort"
    static let defaultEnabled = false
    static let defaultPort = 8765
    static let minPort = 1024
    static let maxPort = 65535

    static func normalizedPort(_ raw: Int) -> Int {
        min(max(raw, minPort), maxPort)
    }

    static func urlString(port: Int) -> String {
        "http://127.0.0.1:\(normalizedPort(port))"
    }
}

enum RemoteAccessTokenStoreError: Error, LocalizedError {
    case malformedToken
    case unresolvedTokenFilePath
    case tokenGenerationFailed

    var errorDescription: String? {
        switch self {
        case .malformedToken:
            return String(localized: "remoteAccess.token.error.malformed", defaultValue: "Remote access token is empty or malformed.")
        case .unresolvedTokenFilePath:
            return String(localized: "remoteAccess.token.error.unresolvedPath", defaultValue: "Unable to resolve remote access token file path.")
        case .tokenGenerationFailed:
            return String(localized: "remoteAccess.token.error.generationFailed", defaultValue: "Failed to generate remote access token.")
        }
    }
}

enum RemoteAccessTokenStore {
    static let directoryName = "cmux"
    static let fileName = "remote-access-token"
    private static let tokenByteCount = 32

    static func loadOrCreateToken(fileURL: URL? = nil) throws -> String {
        if let existing = try loadToken(fileURL: fileURL) {
            return existing
        }
        let token = try generateToken()
        try saveToken(token, fileURL: fileURL)
        return token
    }

    static func loadToken(fileURL: URL? = nil) throws -> String? {
        guard let fileURL = fileURL ?? defaultTokenFileURL() else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let token = String(data: data, encoding: .utf8) else { return nil }
        return normalizedToken(token)
    }

    @discardableResult
    static func rotateToken(fileURL: URL? = nil) throws -> String {
        let token = try generateToken()
        try saveToken(token, fileURL: fileURL)
        return token
    }

    static func saveToken(_ token: String, fileURL: URL? = nil) throws {
        guard let normalized = normalizedToken(token) else {
            throw RemoteAccessTokenStoreError.malformedToken
        }
        guard let fileURL = fileURL ?? defaultTokenFileURL() else {
            throw RemoteAccessTokenStoreError.unresolvedTokenFilePath
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((normalized + "\n").utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func verify(candidate: String, expected: String) -> Bool {
        guard let normalizedCandidate = normalizedToken(candidate),
              let normalizedExpected = normalizedToken(expected) else {
            return false
        }
        return constantTimeEquals(normalizedCandidate, normalizedExpected)
    }

    static func defaultTokenFileURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func normalizedToken(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 32 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }) else {
            return nil
        }
        return trimmed
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemoteAccessTokenStoreError.tokenGenerationFailed
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let count = max(lhsBytes.count, rhsBytes.count)
        var diff = lhsBytes.count ^ rhsBytes.count
        for index in 0..<count {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            diff |= Int(lhsByte ^ rhsByte)
        }
        return diff == 0
    }
}

struct CMUXRemoteHTTPResponse: Equatable {
    let statusCode: Int
    let body: String
    let eventReason: CMUXRemoteEventReason?

    init(statusCode: Int, body: String, eventReason: CMUXRemoteEventReason? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.eventReason = eventReason
    }
}

enum RemoteAccessServerState: Equatable {
    case stopped
    case starting(port: Int)
    case running(port: Int)
    case stopping(port: Int)
    case restarting(fromPort: Int, toPort: Int)
    case failed(port: Int, message: String)

    var failureMessage: String? {
        if case .failed(_, let message) = self {
            return message
        }
        return nil
    }
}

enum CMUXRemoteEventReason: String, CaseIterable, Sendable {
    case remoteMutation = "remote_mutation"
    case workspace
    case surface
    case notification
    case feed
}

enum CMUXRemoteEvents {
    nonisolated static func publishSnapshotChanged(reason: CMUXRemoteEventReason) {
        Task {
            await CMUXRemoteEventHub.shared.publishSnapshotChanged(reason: reason)
        }
    }
}

actor CMUXRemoteEventHub {
    struct Configuration: Sendable {
        var coalesceNanoseconds: UInt64
        var keepaliveNanoseconds: UInt64?
        var finishAfterInitialFrame: Bool

        static let production = Configuration(
            coalesceNanoseconds: 250_000_000,
            keepaliveNanoseconds: 15_000_000_000,
            finishAfterInitialFrame: false
        )
    }

    static let shared = CMUXRemoteEventHub()

    private struct Subscriber {
        let continuation: AsyncStream<String>.Continuation
        var keepaliveTask: Task<Void, Never>?
    }

    private let configuration: Configuration
    private var subscribers: [UUID: Subscriber] = [:]
    private var nextSequence: UInt64 = 0
    private var pendingReasons = Set<CMUXRemoteEventReason>()
    private var coalesceTask: Task<Void, Never>?

    init(configuration: Configuration = .production) {
        self.configuration = configuration
    }

    func subscribe() -> AsyncStream<String> {
        let id = UUID()
        let stream = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(16))
        stream.continuation.onTermination = { @Sendable _ in
            Task { await self.removeSubscriber(id) }
        }
        addSubscriber(id: id, continuation: stream.continuation)
        return stream.stream
    }

    func publishSnapshotChanged(reason: CMUXRemoteEventReason) {
        pendingReasons.insert(reason)
        guard coalesceTask == nil else { return }

        let delay = configuration.coalesceNanoseconds
        coalesceTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            await self?.flushSnapshotChanged()
        }
    }

    private func addSubscriber(id: UUID, continuation: AsyncStream<String>.Continuation) {
        var subscriber = Subscriber(continuation: continuation, keepaliveTask: nil)
        if let keepaliveNanoseconds = configuration.keepaliveNanoseconds {
            subscriber.keepaliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: keepaliveNanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.sendKeepalive(to: id)
                }
            }
        }
        subscribers[id] = subscriber
        guard yield(Self.helloFrame(), to: id) else { return }
        if configuration.finishAfterInitialFrame {
            continuation.finish()
            removeSubscriber(id)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.keepaliveTask?.cancel()
    }

    private func sendKeepalive(to id: UUID) {
        yield(": keepalive\n\n", to: id)
    }

    private func flushSnapshotChanged() {
        coalesceTask = nil
        guard !subscribers.isEmpty, !pendingReasons.isEmpty else {
            pendingReasons.removeAll()
            return
        }

        nextSequence &+= 1
        let reasons = pendingReasons.map(\.rawValue).sorted()
        pendingReasons.removeAll()

        let payload: [String: Any] = [
            "sequence": nextSequence,
            "reasons": reasons,
        ]
        broadcast(Self.eventFrame(name: "snapshot_changed", id: nextSequence, payload: payload))
    }

    private func broadcast(_ frame: String) {
        for id in Array(subscribers.keys) {
            yield(frame, to: id)
        }
    }

    @discardableResult
    private func yield(_ frame: String, to id: UUID) -> Bool {
        guard let subscriber = subscribers[id] else { return false }
        switch subscriber.continuation.yield(frame) {
        case .terminated:
            removeSubscriber(id)
            return false
        default:
            return true
        }
    }

    func subscriberCountForTesting() -> Int {
        subscribers.count
    }

    private static func helloFrame() -> String {
        eventFrame(name: "hello", id: 0, payload: ["ok": true], prefix: "retry: 2000\n")
    }

    private static func eventFrame(name: String, id: UInt64, payload: [String: Any], prefix: String = "") -> String {
        let data = jsonLine(payload)
        return "\(prefix)event: \(name)\nid: \(id)\ndata: \(data)\n\n"
    }

    private static func jsonLine(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false}"#
        }
        return string
    }
}

final class CMUXRemoteRPCHandler: @unchecked Sendable {
    typealias TokenLoader = @Sendable () throws -> String?
    typealias Dispatcher = @Sendable (String) async -> String

    static let maxBodyBytes = 1_048_576

    static let remoteAllowedMethods: [String] = [
        "system.ping",
        "system.capabilities",
        "system.identify",
        "system.tree",
        "workspace.create",
        "workspace.list",
        "workspace.current",
        "surface.create",
        "surface.health",
        "surface.list",
        "surface.current",
        "surface.read_text",
        "surface.send_text",
        "surface.send_key",
        "notification.list",
        "feed.list",
    ].sorted()

    private static let allowedMethods = Set(remoteAllowedMethods)
    private static let mutatingMethods: Set<String> = [
        "workspace.create",
        "surface.create",
        "surface.send_key",
        "surface.send_text",
    ]

    private let loadToken: TokenLoader
    private let dispatch: Dispatcher

    init(loadToken: @escaping TokenLoader, dispatch: @escaping Dispatcher) {
        self.loadToken = loadToken
        self.dispatch = dispatch
    }

    func handle(body: Data, authorizationHeader: String?) async -> CMUXRemoteHTTPResponse {
        let parsedId = Self.extractIdIfPossible(from: body)

        guard body.count <= Self.maxBodyBytes else {
            return Self.jsonError(statusCode: 413, id: parsedId, code: "content_too_large", message: "Request body is too large.")
        }

        if let authError = authenticationError(id: parsedId, authorizationHeader: authorizationHeader) {
            return authError
        }

        guard let object = try? JSONSerialization.jsonObject(with: body, options: []),
              let dict = object as? [String: Any] else {
            return Self.jsonError(statusCode: 400, id: parsedId, code: "parse_error", message: "Request body must be a JSON object.")
        }

        let id = dict["id"]
        guard let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !method.isEmpty else {
            return Self.jsonError(statusCode: 400, id: id, code: "invalid_request", message: "Request body requires a non-empty method.")
        }

        let params: [String: Any]
        if let rawParams = dict["params"] {
            guard let objectParams = rawParams as? [String: Any] else {
                return Self.jsonError(statusCode: 400, id: id, code: "invalid_request", message: "params must be a JSON object.")
            }
            params = objectParams
        } else {
            params = [:]
        }

        guard Self.allowedMethods.contains(method) else {
            return Self.jsonError(statusCode: 403, id: id, code: "method_not_allowed", message: "Method is not available over remote access.")
        }

        if method == "system.capabilities" {
            return Self.jsonResponse(
                statusCode: 200,
                payload: [
                    "id": id ?? NSNull(),
                    "ok": true,
                    "result": [
                        "protocol": "cmux-remote-http",
                        "version": 1,
                        "methods": Self.remoteAllowedMethods,
                    ],
                ]
            )
        }

        var forwarded: [String: Any] = [
            "method": method,
            "params": params,
        ]
        if let id {
            forwarded["id"] = id
        }

        guard JSONSerialization.isValidJSONObject(forwarded),
              let data = try? JSONSerialization.data(withJSONObject: forwarded, options: []),
              let line = String(data: data, encoding: .utf8) else {
            return Self.jsonError(statusCode: 400, id: id, code: "invalid_request", message: "Request could not be forwarded.")
        }

        let response = await dispatch(line)
        let eventReason: CMUXRemoteEventReason? = Self.mutatingMethods.contains(method) && Self.isSuccessfulResponse(response)
            ? .remoteMutation
            : nil
        return CMUXRemoteHTTPResponse(statusCode: 200, body: response, eventReason: eventReason)
    }

    func handleSnapshot(authorizationHeader: String?) async -> CMUXRemoteHTTPResponse {
        if let authError = authenticationError(id: nil, authorizationHeader: authorizationHeader) {
            return authError
        }

        let forwarded: [String: Any] = [
            "method": "system.tree",
            "params": [
                "all_windows": true,
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: forwarded, options: []),
              let line = String(data: data, encoding: .utf8) else {
            return Self.jsonError(statusCode: 500, id: nil, code: "internal_error", message: "Snapshot request could not be forwarded.")
        }

        let response = await dispatch(line)
        return CMUXRemoteHTTPResponse(statusCode: 200, body: response)
    }

    func handleEventAuthentication(authorizationHeader: String?, queryToken: String?) -> CMUXRemoteHTTPResponse? {
        authenticationError(id: nil, authorizationHeader: authorizationHeader, queryToken: queryToken)
    }

    private func authenticationError(id: Any?, authorizationHeader: String?, queryToken: String? = nil) -> CMUXRemoteHTTPResponse? {
        let expectedToken: String
        do {
            guard let loadedToken = try loadToken() else {
                return Self.jsonError(statusCode: 401, id: id, code: "auth_unconfigured", message: "Remote access token is not configured.")
            }
            expectedToken = loadedToken
        } catch {
            return Self.jsonError(statusCode: 500, id: id, code: "auth_unavailable", message: "Remote access token could not be loaded.")
        }

        guard let providedToken = Self.bearerToken(from: authorizationHeader) ?? Self.queryToken(queryToken),
              RemoteAccessTokenStore.verify(candidate: providedToken, expected: expectedToken) else {
            return Self.jsonError(statusCode: 401, id: id, code: "unauthorized", message: "Missing or invalid remote access token.")
        }

        return nil
    }

    private static func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader else { return nil }
        let trimmed = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Bearer "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let token = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func queryToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractIdIfPossible(from body: Data) -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: []),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict["id"]
    }

    private static func isSuccessfulResponse(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              let ok = dict["ok"] as? Bool else {
            return true
        }
        return ok
    }

    private static func jsonError(statusCode: Int, id: Any?, code: String, message: String) -> CMUXRemoteHTTPResponse {
        let payload: [String: Any] = [
            "id": id ?? NSNull(),
            "ok": false,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        return jsonResponse(statusCode: statusCode, payload: payload)
    }

    private static func jsonResponse(statusCode: Int, payload: [String: Any]) -> CMUXRemoteHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let body = String(data: data, encoding: .utf8) ?? #"{"ok":false,"error":{"code":"internal_error","message":"Failed to encode error response."}}"#
        return CMUXRemoteHTTPResponse(statusCode: statusCode, body: body)
    }
}

#if canImport(Hummingbird)
@MainActor
final class CMUXRemoteServer: ObservableObject {
    typealias TokenBootstrap = @MainActor @Sendable () throws -> Void
    typealias ApplicationRunner = @Sendable (
        _ port: Int,
        _ handler: CMUXRemoteRPCHandler,
        _ onRunning: @escaping @Sendable () async -> Void
    ) async throws -> Void

    static let shared = CMUXRemoteServer()

    @Published private(set) var state: RemoteAccessServerState = .stopped

    private var task: Task<Void, Never>?
    private var activePort: Int?
    private var pendingStartPort: Int?
    private var startGeneration = 0
    private var eventObservers: [NSObjectProtocol] = []
    private let tokenBootstrap: TokenBootstrap
    private let runApplication: ApplicationRunner

    var isRunning: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    var lastErrorMessage: String? {
        state.failureMessage
    }

    nonisolated func publishSnapshotChanged(reason: CMUXRemoteEventReason) {
        CMUXRemoteEvents.publishSnapshotChanged(reason: reason)
    }

    init(
        tokenBootstrap: @escaping TokenBootstrap = {
            _ = try RemoteAccessTokenStore.loadOrCreateToken()
        },
        runApplication: @escaping ApplicationRunner = CMUXRemoteServer.defaultRunApplication
    ) {
        self.tokenBootstrap = tokenBootstrap
        self.runApplication = runApplication
        installEventObservers()
    }

    deinit {
        for observer in eventObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(port rawPort: Int) {
        let port = RemoteAccessSettings.normalizedPort(rawPort)
        if task != nil, activePort == port, pendingStartPort == nil, isStartingOrRunning(on: port) {
            return
        }

        if task != nil {
            pendingStartPort = port
            if let activePort {
                state = .restarting(fromPort: activePort, toPort: port)
            }
            task?.cancel()
            return
        }

        startFresh(port: port)
    }

    func stop() {
        pendingStartPort = nil
        guard let task else {
            activePort = nil
            state = .stopped
            return
        }

        if let activePort {
            state = .stopping(port: activePort)
        }
        task.cancel()
    }

    private func startFresh(port: Int) {
        startGeneration += 1
        let generation = startGeneration

        do {
            try tokenBootstrap()
        } catch {
            state = .failed(port: port, message: error.localizedDescription)
            return
        }

        let handler = CMUXRemoteRPCHandler(
            loadToken: {
                try RemoteAccessTokenStore.loadToken()
            },
            dispatch: { line in
                await MainActor.run {
                    TerminalController.shared.handleSocketLine(line)
                }
            }
        )
        activePort = port
        state = .starting(port: port)

        let runApplication = self.runApplication
        let onRunning: @Sendable () async -> Void = { [weak self] in
            await MainActor.run {
                guard let self,
                      self.startGeneration == generation,
                      self.activePort == port,
                      self.pendingStartPort == nil,
                      self.isStarting(on: port) else {
                    return
                }
                self.state = .running(port: port)
            }
        }

        task = Task.detached(priority: .background) { [weak self, handler, onRunning, runApplication] in
            do {
                try await runApplication(port, handler, onRunning)
                await MainActor.run {
                    self?.finishListener(generation: generation, port: port, completion: .stopped)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishListener(generation: generation, port: port, completion: .stopped)
                }
            } catch {
                await MainActor.run {
                    self?.finishListener(generation: generation, port: port, completion: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func finishListener(generation: Int, port: Int, completion: ListenerCompletion) {
        guard startGeneration == generation, activePort == port else { return }

        let wasStopping = isStopping(on: port)
        task = nil
        activePort = nil
        if let pendingStartPort {
            self.pendingStartPort = nil
            startFresh(port: pendingStartPort)
            return
        }

        switch completion {
        case .stopped:
            state = .stopped
        case .failed(let message):
            state = wasStopping ? .stopped : .failed(port: port, message: message)
        }
    }

    private func isStarting(on port: Int) -> Bool {
        if case .starting(let currentPort) = state {
            return currentPort == port
        }
        return false
    }

    private func isStopping(on port: Int) -> Bool {
        if case .stopping(let currentPort) = state {
            return currentPort == port
        }
        return false
    }

    private func isStartingOrRunning(on port: Int) -> Bool {
        switch state {
        case .starting(let currentPort), .running(let currentPort):
            return currentPort == port
        case .stopped, .stopping, .restarting, .failed:
            return false
        }
    }

    private func installEventObservers() {
        for (name, reason) in [
            (Notification.Name.ghosttyDidSetTitle, CMUXRemoteEventReason.surface),
            (Notification.Name.ghosttyDidFocusTab, CMUXRemoteEventReason.workspace),
            (Notification.Name.ghosttyDidFocusSurface, CMUXRemoteEventReason.surface),
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                CMUXRemoteEvents.publishSnapshotChanged(reason: reason)
            }
            eventObservers.append(observer)
        }
    }

    nonisolated private static func defaultRunApplication(
        port: Int,
        handler: CMUXRemoteRPCHandler,
        onRunning: @escaping @Sendable () async -> Void
    ) async throws {
        let app = makeApplication(port: port, handler: handler, onRunning: onRunning)
        try await app.runService(gracefulShutdownSignals: [])
    }

    nonisolated static func makeApplication(
        port: Int,
        handler: CMUXRemoteRPCHandler,
        eventHub: CMUXRemoteEventHub = .shared,
        onRunning: @escaping @Sendable () async -> Void = {}
    ) -> Application<Router<BasicRequestContext>.Responder> {
        let router = Router()
        router.add(
            middleware: CORSMiddleware(
                allowOrigin: .originBased,
                allowHeaders: [.authorization, .contentType, .accept, .origin],
                allowMethods: [.get, .post, .options],
                allowCredentials: true,
                maxAge: .seconds(600)
            )
        )
        router.post("rpc") { request, _ -> Response in
            var request = request
            let buffer = try await request.collectBody(upTo: CMUXRemoteRPCHandler.maxBodyBytes + 1)
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) ?? Data()
            let result = await handler.handle(body: data, authorizationHeader: request.headers[.authorization])
            if let eventReason = result.eventReason {
                await eventHub.publishSnapshotChanged(reason: eventReason)
            }
            return Self.response(statusCode: result.statusCode, body: result.body)
        }
        router.get("snapshot") { request, _ -> Response in
            let result = await handler.handleSnapshot(authorizationHeader: request.headers[.authorization])
            return Self.response(statusCode: result.statusCode, body: result.body)
        }
        router.get("events") { request, _ -> Response in
            let queryToken = request.uri.queryParameters["token"].map(String.init)
            if let authError = handler.handleEventAuthentication(
                authorizationHeader: request.headers[.authorization],
                queryToken: queryToken
            ) {
                return Self.response(statusCode: authError.statusCode, body: authError.body)
            }

            let stream = await eventHub.subscribe()
            return Self.eventStreamResponse(stream: stream)
        }
        for path in ["/", "/remote", "/remote/strings.json", "/remote/manifest.webmanifest", "/remote/icon.svg", "/remote/maskable-icon.svg", "/remote/icon-maskable.svg"] {
            router.get(RouterPath(path)) { _, _ -> Response in
                guard let asset = CMUXRemoteWebClient.asset(path: path) else {
                    return Self.response(statusCode: 404, body: #"{"ok":false,"error":{"code":"not_found","message":"Asset not found."}}"#)
                }
                return Self.staticResponse(asset: asset)
            }
        }
        router.get("remote/assets/**") { _, context -> Response in
            let relativePath = context.parameters.getCatchAll().map(String.init).joined(separator: "/")
            guard !relativePath.isEmpty,
                  let asset = CMUXRemoteWebClient.asset(path: "/remote/assets/\(relativePath)") else {
                return Self.response(statusCode: 404, body: #"{"ok":false,"error":{"code":"not_found","message":"Asset not found."}}"#)
            }
            return Self.staticResponse(asset: asset)
        }
        return Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "cmux-remote"
            ),
            onServerRunning: { _ in
                await onRunning()
            }
        )
    }

    nonisolated private static func response(statusCode: Int, body: String) -> Response {
        let buffer = ByteBuffer(string: body)
        let status = HTTPResponse.Status(code: statusCode)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = buffer.readableBytes.description
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }

    nonisolated private static func eventStreamResponse(stream: AsyncStream<String>) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream; charset=utf-8"
        headers[.cacheControl] = "no-cache"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(contentLength: nil) { writer in
                for await frame in stream {
                    try await writer.write(ByteBuffer(string: frame))
                }
                try await writer.finish(nil)
            }
        )
    }

    nonisolated private static func staticResponse(asset: CMUXRemoteWebClient.Asset) -> Response {
        let buffer = ByteBuffer(string: asset.body)
        var headers = HTTPFields()
        headers[.contentType] = asset.contentType
        headers[.contentLength] = buffer.readableBytes.description
        headers[.cacheControl] = "no-store"
        headers[.contentSecurityPolicy] = "default-src 'self'; connect-src 'self'; img-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        headers[.xContentTypeOptions] = "nosniff"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }
}
#else
@MainActor
final class CMUXRemoteServer: ObservableObject {
    static let shared = CMUXRemoteServer()

    @Published private(set) var state: RemoteAccessServerState = .stopped

    var lastErrorMessage: String? {
        state.failureMessage
    }

    var isRunning: Bool { false }

    func start(port rawPort: Int) {
        state = .failed(
            port: RemoteAccessSettings.normalizedPort(rawPort),
            message: String(localized: "remoteAccess.server.error.unavailableInBuild", defaultValue: "Remote access server is unavailable in this build.")
        )
    }

    func stop() {
        state = .stopped
    }

    nonisolated func publishSnapshotChanged(reason: CMUXRemoteEventReason) {
    }
}
#endif

private enum ListenerCompletion {
    case stopped
    case failed(String)
}
