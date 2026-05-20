import Darwin
import Foundation

enum CodexAppServerClientError: Error, LocalizedError {
    case alreadyRunning
    case notRunning
    case processExited
    case invalidResponse(String)
    case requestFailed(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return String(localized: "codexAppServer.error.alreadyRunning", defaultValue: "Codex app-server is already running.")
        case .notRunning:
            return String(localized: "codexAppServer.error.notRunning", defaultValue: "Codex app-server is not running.")
        case .processExited:
            return String(localized: "codexAppServer.error.processExited", defaultValue: "Codex app-server exited.")
        case .invalidResponse(let message):
            let format = String(
                localized: "codexAppServer.error.invalidResponse",
                defaultValue: "Invalid Codex app-server response: %@"
            )
            return String(format: format, locale: Locale.current, message)
        case .requestFailed(let message):
            let format = String(
                localized: "codexAppServer.error.requestFailed",
                defaultValue: "Codex app-server request failed: %@"
            )
            return String(format: format, locale: Locale.current, message)
        case .writeFailed:
            return String(localized: "codexAppServer.error.writeFailed", defaultValue: "Failed to write to Codex app-server.")
        }
    }
}

enum CodexAppServerEvent {
    case notification(CodexAppServerServerNotification)
    case serverRequest(CodexAppServerServerRequest)
    case stderr(String)
    case terminated(Int32)
}

enum CodexAppServerRequestID: Hashable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .int(let value):
            return value
        case .string(let value):
            return value
        }
    }

    var description: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }
}

struct CodexAppServerLaunchConfiguration: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

protocol CodexAppServerClienting: AnyObject {
    var onEvent: ((CodexAppServerEvent) -> Void)? { get set }

    func stop()
    func startAndInitialize() async throws
    func startThread(cwd: String?, model: String?, serviceTier: String?) async throws -> String
    func resumeThread(threadId: String, cwd: String?) async throws -> [String: Any]
    func startTurn(
        threadId: String,
        text: String,
        cwd: String?,
        model: String?,
        serviceTier: String?,
        reasoningSummary: String?
    ) async throws -> String
    func listModels(includeHidden: Bool) async throws -> [[String: Any]]
    func readRateLimits() async throws -> [String: Any]
    func steerTurn(threadId: String, turnId: String, text: String) async throws -> String
    func interruptTurn(threadId: String, turnId: String) async throws
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) throws
    func rejectServerRequest(id: CodexAppServerRequestID, message: String) throws
}

enum CodexAppServerRequestFactory {
    static func request(id: Int, method: String, params: [String: Any]? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            object["params"] = params
        }
        return object
    }

    static func notification(method: String, params: [String: Any]? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            object["params"] = params
        }
        return object
    }

    static func response(id: Int, result: [String: Any]) -> [String: Any] {
        response(id: .int(id), result: result)
    }

    static func response(id: CodexAppServerRequestID, result: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result,
        ]
    }

    static func errorResponse(id: Int, message: String) -> [String: Any] {
        errorResponse(id: .int(id), message: message)
    }

    static func errorResponse(id: CodexAppServerRequestID, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": [
                "code": -32000,
                "message": message,
            ],
        ]
    }

    static func initializeRequest(id: Int) -> [String: Any] {
        request(
            id: id,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "cmux",
                    "title": "cmux",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ]
        )
    }

    static func initializedNotification() -> [String: Any] {
        notification(method: "initialized")
    }

    static func threadStartRequest(id: Int, cwd: String?, model: String? = nil, serviceTier: String? = nil) -> [String: Any] {
        var params: [String: Any] = [
            "serviceName": "cmux",
            "ephemeral": false,
        ]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = cwd
        }
        if let model, !model.isEmpty {
            params["model"] = model
        }
        if let serviceTier, !serviceTier.isEmpty {
            params["serviceTier"] = serviceTier
        }
        return request(id: id, method: "thread/start", params: params)
    }

    static func threadResumeRequest(id: Int, threadId: String, cwd: String?) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
        ]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = cwd
        }
        return request(id: id, method: "thread/resume", params: params)
    }

    static func turnStartRequest(
        id: Int,
        threadId: String,
        text: String,
        cwd: String?,
        model: String? = nil,
        serviceTier: String? = nil,
        reasoningSummary: String? = nil
    ) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [
                [
                    "type": "text",
                    "text": text,
                    "text_elements": [],
                ],
            ],
        ]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = cwd
        }
        if let model, !model.isEmpty {
            params["model"] = model
        }
        if let serviceTier, !serviceTier.isEmpty {
            params["serviceTier"] = serviceTier
        }
        if let reasoningSummary, !reasoningSummary.isEmpty {
            params["summary"] = reasoningSummary
        }
        return request(id: id, method: "turn/start", params: params)
    }

    static func modelListRequest(id: Int, includeHidden: Bool = false) -> [String: Any] {
        request(
            id: id,
            method: "model/list",
            params: [
                "includeHidden": includeHidden,
            ]
        )
    }

    static func accountRateLimitsReadRequest(id: Int) -> [String: Any] {
        request(id: id, method: "account/rateLimits/read")
    }

    static func turnSteerRequest(id: Int, threadId: String, turnId: String, text: String) -> [String: Any] {
        request(
            id: id,
            method: "turn/steer",
            params: [
                "threadId": threadId,
                "expectedTurnId": turnId,
                "input": [
                    [
                        "type": "text",
                        "text": text,
                        "text_elements": [],
                    ],
                ],
            ]
        )
    }

    static func turnInterruptRequest(id: Int, threadId: String, turnId: String) -> [String: Any] {
        request(
            id: id,
            method: "turn/interrupt",
            params: [
                "threadId": threadId,
                "turnId": turnId,
            ]
        )
    }
}

struct CodexAppServerLineBuffer {
    private var buffer = Data()
    private var scanOffset = 0
    private var isDroppingUntilNextLine = false

    var bufferedByteCount: Int {
        buffer.count
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        if isDroppingUntilNextLine {
            guard let newline = data.firstIndex(of: 0x0A) else {
                return []
            }
            isDroppingUntilNextLine = false
            let remainderStart = data.index(after: newline)
            guard remainderStart < data.endIndex else {
                return []
            }
            return append(Data(data[remainderStart..<data.endIndex]))
        }

        buffer.append(data)

        var lines: [Data] = []
        while scanOffset < buffer.endIndex {
            guard let newline = buffer[scanOffset..<buffer.endIndex].firstIndex(of: 0x0A) else {
                scanOffset = buffer.endIndex
                break
            }

            let lineData = Data(buffer[..<newline])
            buffer.removeSubrange(..<buffer.index(after: newline))
            scanOffset = buffer.startIndex
            if !lineData.isEmpty {
                lines.append(lineData)
            }
        }
        return lines
    }

    func bufferedPrefix(maxBytes: Int) -> Data {
        guard maxBytes > 0, !buffer.isEmpty else { return Data() }
        let end = buffer.index(buffer.startIndex, offsetBy: min(maxBytes, buffer.count))
        return Data(buffer[buffer.startIndex..<end])
    }

    mutating func dropBufferedLineUntilNextNewline() {
        buffer.removeAll(keepingCapacity: false)
        scanOffset = buffer.startIndex
        isDroppingUntilNextLine = true
    }

    mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        buffer.removeAll(keepingCapacity: keepCapacity)
        scanOffset = buffer.startIndex
        isDroppingUntilNextLine = false
    }

    mutating func finish() -> Data? {
        guard !isDroppingUntilNextLine else {
            removeAll(keepingCapacity: false)
            return nil
        }
        guard !buffer.isEmpty else { return nil }
        let data = buffer
        buffer.removeAll(keepingCapacity: false)
        scanOffset = buffer.startIndex
        return data
    }
}

final class CodexAppServerClient: CodexAppServerClienting, @unchecked Sendable {
    typealias EventHandler = (CodexAppServerEvent) -> Void

    private final class QueueIdentity {}

    private final class PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let maximumResponseBytesToParse: Int?
        let oversizedResponseFallback: [String: Any]?
#if DEBUG
        let method: String
        let startedAt: UInt64
        var requestBytes = 0
#endif

        init(
            _ continuation: CheckedContinuation<[String: Any], Error>,
            method: String,
            maximumResponseBytesToParse: Int? = nil,
            oversizedResponseFallback: [String: Any]? = nil
        ) {
            self.continuation = continuation
            self.maximumResponseBytesToParse = maximumResponseBytesToParse
            self.oversizedResponseFallback = oversizedResponseFallback
#if DEBUG
            self.method = method
            self.startedAt = CodexAppServerTiming.now()
#endif
        }

        func fallbackIfOversized(byteCount: Int) -> [String: Any]? {
            guard let maximumResponseBytesToParse,
                  byteCount > maximumResponseBytesToParse else {
                return nil
            }
            return oversizedResponseFallback
        }
    }

    private static let maximumResumeResponseBytesToParse = 16 * 1024 * 1024
    private static let stateQueueSpecificKey = DispatchSpecificKey<QueueIdentity>()

    private let stateQueue = DispatchQueue(label: "cmux.codexAppServerClient.state")
    private let stateQueueIdentity = QueueIdentity()
    private let callbackQueue: DispatchQueue
    private let provider: AgentSessionProvider
    private let executableResolver: AgentExecutableResolver
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutLineBuffer = CodexAppServerLineBuffer()
    private var nextRequestId = 1
    private var pending: [CodexAppServerRequestID: PendingRequest] = [:]
    private var eventHandler: EventHandler?

    var onEvent: EventHandler? {
        get {
            if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) === stateQueueIdentity {
                return eventHandler
            }
            return stateQueue.sync { eventHandler }
        }
        set {
            if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) === stateQueueIdentity {
                eventHandler = newValue
            } else {
                stateQueue.sync {
                    eventHandler = newValue
                }
            }
        }
    }

    init(
        provider: AgentSessionProvider = .provider(.codex),
        callbackQueue: DispatchQueue = .main,
        executableResolver: AgentExecutableResolver = AgentExecutableResolver()
    ) {
        self.provider = provider
        self.callbackQueue = callbackQueue
        self.executableResolver = executableResolver
        stateQueue.setSpecific(key: Self.stateQueueSpecificKey, value: stateQueueIdentity)
    }

    deinit {
        stopFromDeinit()
    }

    func start() throws {
        let result: Result<Void, Error> = stateQueue.sync {
            do {
                try startLocked()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    func stop() {
        stateQueue.async {
            self.stopLocked()
        }
    }

    private func stopFromDeinit() {
        if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) === stateQueueIdentity {
            stopLocked()
        } else {
            stateQueue.sync {
                stopLocked()
            }
        }
    }

    func startAndInitialize() async throws {
#if DEBUG
        let timingStart = CodexAppServerTiming.now()
        CodexAppServerTiming.log("client.initialize.begin")
#endif
        do {
            try start()
            _ = try await sendRequestObject(CodexAppServerRequestFactory.initializeRequest(id: nextId()))
            try sendNotificationObject(CodexAppServerRequestFactory.initializedNotification())
#if DEBUG
            CodexAppServerTiming.log("client.initialize.end", [
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: timingStart)),
            ])
#endif
        } catch {
            stopSynchronously()
#if DEBUG
            CodexAppServerTiming.log("client.initialize.error", [
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: timingStart)),
                "error": error.localizedDescription,
            ])
#endif
            throw error
        }
    }

    func startThread(cwd: String?, model: String? = nil, serviceTier: String? = nil) async throws -> String {
        let response = try await sendRequestObject(
            CodexAppServerRequestFactory.threadStartRequest(
                id: nextId(),
                cwd: cwd,
                model: model,
                serviceTier: serviceTier
            )
        )
        guard let thread = response["thread"] as? [String: Any],
              let threadId = thread["id"] as? String,
              !threadId.isEmpty else {
            throw CodexAppServerClientError.invalidResponse("thread/start response did not include thread.id")
        }
        return threadId
    }

    func resumeThread(threadId: String, cwd: String?) async throws -> [String: Any] {
        let response = try await sendRequestObject(
            CodexAppServerRequestFactory.threadResumeRequest(id: nextId(), threadId: threadId, cwd: cwd),
            maximumResponseBytesToParse: Self.maximumResumeResponseBytesToParse,
            oversizedResponseFallback: [
                "thread": ["id": threadId],
                "_cmuxResponseTruncated": true,
            ]
        )
        guard let thread = response["thread"] as? [String: Any],
              let resumedThreadId = thread["id"] as? String,
              !resumedThreadId.isEmpty else {
            throw CodexAppServerClientError.invalidResponse("thread/resume response did not include thread.id")
        }
        return response
    }

    func startTurn(
        threadId: String,
        text: String,
        cwd: String?,
        model: String? = nil,
        serviceTier: String? = nil,
        reasoningSummary: String? = nil
    ) async throws -> String {
        let response = try await sendRequestObject(
            CodexAppServerRequestFactory.turnStartRequest(
                id: nextId(),
                threadId: threadId,
                text: text,
                cwd: cwd,
                model: model,
                serviceTier: serviceTier,
                reasoningSummary: reasoningSummary
            )
        )
        guard let turn = response["turn"] as? [String: Any],
              let turnId = turn["id"] as? String,
              !turnId.isEmpty else {
            throw CodexAppServerClientError.invalidResponse("turn/start response did not include turn.id")
        }
        return turnId
    }

    func listModels(includeHidden: Bool = false) async throws -> [[String: Any]] {
        let response = try await sendRequestObject(
            CodexAppServerRequestFactory.modelListRequest(id: nextId(), includeHidden: includeHidden)
        )
        guard let data = response["data"] as? [[String: Any]] else {
            throw CodexAppServerClientError.invalidResponse("model/list response did not include data")
        }
        return data
    }

    func readRateLimits() async throws -> [String: Any] {
        try await sendRequestObject(CodexAppServerRequestFactory.accountRateLimitsReadRequest(id: nextId()))
    }

    func steerTurn(threadId: String, turnId: String, text: String) async throws -> String {
        let response = try await sendRequestObject(
            CodexAppServerRequestFactory.turnSteerRequest(
                id: nextId(),
                threadId: threadId,
                turnId: turnId,
                text: text
            )
        )
        guard let returnedTurnId = response["turnId"] as? String,
              !returnedTurnId.isEmpty else {
            throw CodexAppServerClientError.invalidResponse("turn/steer response did not include turnId")
        }
        return returnedTurnId
    }

    func interruptTurn(threadId: String, turnId: String) async throws {
        _ = try await sendRequestObject(
            CodexAppServerRequestFactory.turnInterruptRequest(
                id: nextId(),
                threadId: threadId,
                turnId: turnId
            )
        )
    }

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) throws {
        try sendResponseObject(CodexAppServerRequestFactory.response(id: id, result: result))
    }

    func rejectServerRequest(id: CodexAppServerRequestID, message: String) throws {
        try sendResponseObject(CodexAppServerRequestFactory.errorResponse(id: id, message: message))
    }

    private func nextId() -> Int {
        stateQueue.sync {
            let id = nextRequestId
            nextRequestId += 1
            return id
        }
    }

    private func startLocked() throws {
        guard process == nil else {
            throw CodexAppServerClientError.alreadyRunning
        }

#if DEBUG
        let start = CodexAppServerTiming.now()
        let configStart = CodexAppServerTiming.now()
#endif
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let configuration = try Self.appServerLaunchConfiguration(
            provider: provider,
            executableResolver: executableResolver
        )
#if DEBUG
        CodexAppServerTiming.log("client.process.config", [
            "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: configStart)),
            "executable": configuration.executablePath,
            "args": configuration.arguments.joined(separator: " "),
        ])
#endif
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.handleTermination(process: process, status: process.terminationStatus)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingestStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else { return }
            self?.emit(.stderr(text))
        }

        guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexAppServerClientError.invalidResponse("failed to configure Codex app-server stdin pipe")
        }

        do {
#if DEBUG
            let runStart = CodexAppServerTiming.now()
#endif
            try process.run()
#if DEBUG
            CodexAppServerTiming.log("client.process.run", [
                "pid": process.processIdentifier,
                "run_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: runStart)),
                "total_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            ])
#endif
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
#if DEBUG
            CodexAppServerTiming.log("client.process.run.error", [
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                "error": error.localizedDescription,
            ])
#endif
            throw error
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    private func stopLocked() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutLineBuffer.removeAll(keepingCapacity: false)
        failPending(CodexAppServerClientError.processExited)
    }

    private func stopSynchronously() {
        if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) === stateQueueIdentity {
            stopLocked()
        } else {
            stateQueue.sync {
                stopLocked()
            }
        }
    }

    static func appServerLaunchConfiguration(
        provider: AgentSessionProvider = .provider(.codex),
        executableResolver: AgentExecutableResolver
    ) throws -> CodexAppServerLaunchConfiguration {
        let launchPlan = try executableResolver.resolveLaunchPlan(for: provider)
        return CodexAppServerLaunchConfiguration(
            executablePath: launchPlan.executablePath,
            arguments: launchPlan.arguments,
            environment: launchPlan.environment
        )
    }

    static func appServerLaunchConfiguration(
        provider: AgentSessionProvider = .provider(.codex),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CodexAppServerLaunchConfiguration {
        try appServerLaunchConfiguration(
            provider: provider,
            executableResolver: AgentExecutableResolver(baseEnvironment: baseEnvironment)
        )
    }

    static func appServerEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        AgentExecutableResolver.providerEnvironment(baseEnvironment: baseEnvironment)
    }

    static func resolvedExecutablePath(
        _ executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        AgentExecutableResolver.resolvedExecutablePath(executable, environment: environment)
    }

    private func sendRequestObject(
        _ object: [String: Any],
        maximumResponseBytesToParse: Int? = nil,
        oversizedResponseFallback: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let id = Self.requestID(from: object["id"]) else {
            throw CodexAppServerClientError.invalidResponse("request object missing numeric id")
        }
        let method = object["method"] as? String ?? "unknown"

        return try await withCheckedThrowingContinuation { continuation in
#if DEBUG
            let enqueueTime = CodexAppServerTiming.now()
#endif
            stateQueue.async {
                guard self.process?.isRunning == true,
                      let stdinPipe = self.stdinPipe else {
                    continuation.resume(throwing: CodexAppServerClientError.notRunning)
                    return
                }

                let pendingRequest = PendingRequest(
                    continuation,
                    method: method,
                    maximumResponseBytesToParse: maximumResponseBytesToParse,
                    oversizedResponseFallback: oversizedResponseFallback
                )
                self.pending[id] = pendingRequest
                do {
                    let bytes = try Self.writeJSONObject(object, to: stdinPipe.fileHandleForWriting)
#if DEBUG
                    pendingRequest.requestBytes = bytes
                    CodexAppServerTiming.log("client.request.sent", [
                        "id": id.description,
                        "method": method,
                        "bytes": bytes,
                        "queue_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: enqueueTime)),
                    ])
#endif
                } catch {
                    self.pending.removeValue(forKey: id)
#if DEBUG
                    CodexAppServerTiming.log("client.request.writeError", [
                        "id": id.description,
                        "method": method,
                        "error": error.localizedDescription,
                    ])
#endif
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendNotificationObject(_ object: [String: Any]) throws {
        let result: Result<Void, Error> = stateQueue.sync {
            do {
                guard process?.isRunning == true,
                      let stdinPipe else {
                    throw CodexAppServerClientError.notRunning
                }
                try Self.writeJSONObject(object, to: stdinPipe.fileHandleForWriting)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    private func sendResponseObject(_ object: [String: Any]) throws {
        let result: Result<Void, Error> = stateQueue.sync {
            do {
                guard process?.isRunning == true,
                      let stdinPipe else {
                    throw CodexAppServerClientError.notRunning
                }
                try Self.writeJSONObject(object, to: stdinPipe.fileHandleForWriting)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    @discardableResult
    private static func writeJSONObject(_ object: [String: Any], to handle: FileHandle) throws -> Int {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerClientError.invalidResponse("request is not valid JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw CodexAppServerClientError.writeFailed
        }
        return data.count
    }

    private func ingestStdout(_ data: Data) {
#if DEBUG
        let enqueueTime = CodexAppServerTiming.now()
#endif
        stateQueue.async {
#if DEBUG
            let appendStart = CodexAppServerTiming.now()
#endif
            let lines = self.stdoutLineBuffer.append(data)
            self.resolveOversizedBufferedResponseIfNeeded()
#if DEBUG
            if data.count >= 4 * 1024 * 1024 || !lines.isEmpty {
                CodexAppServerTiming.log("client.stdout.chunk", [
                    "bytes": data.count,
                    "lines": lines.count,
                    "buffered": self.stdoutLineBuffer.bufferedByteCount,
                    "queue_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: enqueueTime)),
                    "append_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: appendStart)),
                ])
            }
#endif
            for line in lines {
                self.handleStdoutLine(line)
            }
        }
    }

    private func resolveOversizedBufferedResponseIfNeeded() {
        let bufferedByteCount = stdoutLineBuffer.bufferedByteCount
        guard bufferedByteCount > 0 else { return }
        let prefix = stdoutLineBuffer.bufferedPrefix(maxBytes: 64 * 1024)
        guard let id = Self.responseId(in: prefix),
              let request = pending[id],
              Self.containsTopLevelKey("result", in: prefix),
              let fallback = request.fallbackIfOversized(byteCount: bufferedByteCount) else {
            return
        }
        pending.removeValue(forKey: id)
        stdoutLineBuffer.dropBufferedLineUntilNextNewline()
#if DEBUG
        CodexAppServerTiming.log("client.response.oversizedBuffered", [
            "id": id.description,
            "method": request.method,
            "buffered": bufferedByteCount,
            "request_bytes": request.requestBytes,
            "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: request.startedAt)),
        ])
#endif
        request.continuation.resume(returning: fallback)
    }

    private func handleStdoutLine(_ data: Data) {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        if let id = Self.responseId(in: data),
           let request = pending[id],
           !Self.containsTopLevelKey("error", in: data),
           let fallback = request.fallbackIfOversized(byteCount: data.count) {
            pending.removeValue(forKey: id)
#if DEBUG
            CodexAppServerTiming.log("client.response.oversized", [
                "id": id.description,
                "method": request.method,
                "bytes": data.count,
                "request_bytes": request.requestBytes,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: request.startedAt)),
                "scan_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            ])
#endif
            request.continuation.resume(returning: fallback)
            return
        }

#if DEBUG
        let parseStart = CodexAppServerTiming.now()
#endif
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8) {
                emit(.stderr("Unparseable Codex app-server output: \(text)\n"))
            }
            return
        }
#if DEBUG
        let parseMs = CodexAppServerTiming.elapsedMs(since: parseStart)
#endif

        if let id = Self.requestID(from: object["id"]),
           object["result"] != nil || object["error"] != nil {
            let request = pending.removeValue(forKey: id)
#if DEBUG
            if let request {
                CodexAppServerTiming.log("client.response.parsed", [
                    "id": id.description,
                    "method": request.method,
                    "bytes": data.count,
                    "request_bytes": request.requestBytes,
                    "total_ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: request.startedAt)),
                    "parse_ms": CodexAppServerTiming.ms(parseMs),
                    "error": object["error"] != nil,
                ])
            }
#endif
            if let errorObject = object["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? String(describing: errorObject)
                request?.continuation.resume(throwing: CodexAppServerClientError.requestFailed(message))
            } else if let result = object["result"] as? [String: Any] {
                request?.continuation.resume(returning: result)
            } else {
                request?.continuation.resume(returning: [:])
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"]
        if let id = Self.requestID(from: object["id"]) {
            emit(.serverRequest(CodexAppServerServerRequest(id: id, method: method, params: params)))
        } else {
            emit(.notification(CodexAppServerServerNotification(method: method, params: params)))
        }
    }

    private func handleTermination(process terminatedProcess: Process, status: Int32) {
        stateQueue.async {
            guard self.process === terminatedProcess else { return }
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.stdoutLineBuffer.removeAll(keepingCapacity: false)
            self.failPending(CodexAppServerClientError.processExited)
            self.emit(.terminated(status))
        }
    }

    private func failPending(_ error: Error) {
        let pending = self.pending
        self.pending.removeAll()
        for request in pending.values {
            request.continuation.resume(throwing: error)
        }
    }

    private func emit(_ event: CodexAppServerEvent) {
        let handler: EventHandler? = {
            if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) === stateQueueIdentity {
                return eventHandler
            }
            return stateQueue.sync { eventHandler }
        }()
        guard let handler else { return }
        callbackQueue.async {
            handler(event)
        }
    }

    static func requestID(from value: Any?) -> CodexAppServerRequestID? {
        if let value = value as? NSNumber {
            guard !isBooleanNumber(value) else { return nil }
            return .int(value.intValue)
        }
        if let value = value as? Int {
            return .int(value)
        }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .string(trimmed)
        }
        return nil
    }

    private static func isBooleanNumber(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func responseId(in data: Data) -> CodexAppServerRequestID? {
        topLevelRequestID(for: "id", in: data)
    }

    private static func containsTopLevelKey(_ key: String, in data: Data) -> Bool {
        topLevelValueIndex(for: key, in: data) != nil
    }

    private static func topLevelRequestID(for key: String, in data: Data) -> CodexAppServerRequestID? {
        guard let valueIndex = topLevelValueIndex(for: key, in: data) else { return nil }
        return parseRequestIDValue(in: data, startingAt: valueIndex)
    }

    private static func topLevelValueIndex(for key: String, in data: Data) -> Data.Index? {
        var index = data.startIndex
        var depth = 0
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x22 {
                guard let (string, nextIndex) = parseJSONString(in: data, startingAt: index) else {
                    return nil
                }
                if depth == 1, string == key {
                    var valueIndex = skipWhitespace(in: data, startingAt: nextIndex)
                    guard valueIndex < data.endIndex, data[valueIndex] == 0x3A else {
                        index = nextIndex
                        continue
                    }
                    valueIndex = data.index(after: valueIndex)
                    return skipWhitespace(in: data, startingAt: valueIndex)
                }
                index = nextIndex
                continue
            }
            if byte == 0x7B || byte == 0x5B {
                depth += 1
            } else if byte == 0x7D || byte == 0x5D {
                depth = max(0, depth - 1)
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func parseRequestIDValue(in data: Data, startingAt index: Data.Index) -> CodexAppServerRequestID? {
        guard index < data.endIndex else { return nil }
        if data[index] == 0x22,
           let (string, _) = parseJSONString(in: data, startingAt: index) {
            return requestID(from: string)
        }

        var current = index
        var digits = Data()
        if current < data.endIndex, data[current] == 0x2D {
            digits.append(data[current])
            current = data.index(after: current)
        }
        while current < data.endIndex, data[current] >= 0x30, data[current] <= 0x39 {
            digits.append(data[current])
            current = data.index(after: current)
        }
        guard !digits.isEmpty,
              let text = String(data: digits, encoding: .utf8),
              let value = Int(text) else {
            return nil
        }
        return .int(value)
    }

    private static func parseJSONString(in data: Data, startingAt quoteIndex: Data.Index) -> (String, Data.Index)? {
        guard quoteIndex < data.endIndex, data[quoteIndex] == 0x22 else { return nil }
        var index = data.index(after: quoteIndex)
        var bytes = Data()
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if escaped {
                bytes.append(byte)
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return String(data: bytes, encoding: .utf8).map { ($0, data.index(after: index)) }
            } else {
                bytes.append(byte)
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func skipWhitespace(in data: Data, startingAt index: Data.Index) -> Data.Index {
        var index = index
        while index < data.endIndex {
            switch data[index] {
            case 0x09, 0x0A, 0x0D, 0x20:
                index = data.index(after: index)
            default:
                return index
            }
        }
        return index
    }
}
