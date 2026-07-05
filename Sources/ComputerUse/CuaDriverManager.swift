import Darwin
import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class CuaDriverManager {
    struct RunningInfo: Equatable, Sendable {
        let pid: Int32
        let serverName: String?
        let serverVersion: String?
        let toolCount: Int
    }

    enum State: Equatable, Sendable {
        case notFound
        case stopped
        case starting
        case running(RunningInfo)
        case failed(String)
    }

    static let shared = CuaDriverManager()

    private(set) var state: State = .stopped {
        didSet { yieldState(state) }
    }

    @ObservationIgnored private let resolver: CuaDriverBinaryResolver
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var session: CuaDriverProcessSession?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    init(
        resolver: CuaDriverBinaryResolver = CuaDriverBinaryResolver(),
        registerTerminationObserver: Bool = true
    ) {
        self.resolver = resolver
        if registerTerminationObserver {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.terminateForAppTermination()
                }
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func resolve(
        settingValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHelperURL: URL = CuaDriverBinaryResolver.bundleHelperURL(),
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> CuaDriverBinaryResolution? {
        resolver.resolve(
            settingValue: settingValue,
            environment: environment,
            bundleHelperURL: bundleHelperURL,
            fileExists: fileExists
        )
    }

    func resolutionCandidates(
        settingValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHelperURL: URL = CuaDriverBinaryResolver.bundleHelperURL()
    ) -> [CuaDriverBinaryResolution] {
        resolver.candidates(
            settingValue: settingValue,
            environment: environment,
            bundleHelperURL: bundleHelperURL
        )
    }

    func stateUpdates() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func start(
        settingValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHelperURL: URL = CuaDriverBinaryResolver.bundleHelperURL(),
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) async {
        switch state {
        case .starting, .running:
            return
        case .notFound, .stopped, .failed:
            break
        }

        guard let resolution = resolve(
            settingValue: settingValue,
            environment: environment,
            bundleHelperURL: bundleHelperURL,
            fileExists: fileExists
        ) else {
            state = .notFound
            return
        }

        state = .starting

        let process = Process()
        process.executableURL = resolution.url
        process.arguments = ["mcp", "--no-daemon-relaunch"]
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let lineInbox = CuaDriverLineInbox(stream: CuaDriverLineStream.lines(from: stdout.fileHandleForReading))
        let runningSession = CuaDriverProcessSession(
            process: process,
            stdin: stdin,
            stdoutDrainTask: nil,
            stderrDrainTask: CuaDriverLineStream.drain(fileHandle: stderr.fileHandleForReading)
        )
        session = runningSession

        process.terminationHandler = { [weak self, weak runningSession] process in
            let status = process.terminationStatus
            Task { @MainActor in
                await self?.handleTermination(session: runningSession, status: status)
            }
        }

        do {
            try process.run()
            runningSession.pid = process.processIdentifier
            let info = try await performHandshake(input: stdin.fileHandleForWriting, lines: lineInbox, pid: process.processIdentifier)
            guard self.session === runningSession, process.isRunning else { return }
            state = .running(info)
        } catch {
            if self.session === runningSession {
                await stopSession(runningSession, finalState: .failed(error.localizedDescription))
            }
        }
    }

    func stop() async {
        guard let session else {
            if case .notFound = state {
                state = .stopped
            }
            return
        }
        await stopSession(session, finalState: .stopped)
    }

    private func stopSession(_ session: CuaDriverProcessSession, finalState: State) async {
        session.isStopping = true
        let process = session.process
        let terminationInbox = session.terminationInbox

        if process.isRunning {
            terminate(process)

            do {
                _ = try await withTimeout(.seconds(3)) {
                    try await terminationInbox.next()
                }
            } catch {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                _ = try? await terminationInbox.next()
            }
        }

        if self.session === session {
            self.session = nil
        }
        state = finalState
    }

    private func performHandshake(
        input: FileHandle,
        lines: CuaDriverLineInbox,
        pid: Int32
    ) async throws -> RunningInfo {
        try writeJSONObject([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": [
                    "name": "cmux",
                    "version": "dev",
                ],
            ],
        ], to: input)

        let initialize = try await response(id: 1, lines: lines)
        guard initialize.keys.contains("result") else {
            throw CuaDriverManagerError.invalidInitializeResponse
        }
        let serverInfo = (initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        let serverName = serverInfo?["name"] as? String
        let serverVersion = serverInfo?["version"] as? String

        try writeJSONObject([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ], to: input)

        try writeJSONObject([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ], to: input)

        let toolsList = try await response(id: 2, lines: lines)
        guard
            let result = toolsList["result"] as? [String: Any],
            let tools = result["tools"] as? [Any]
        else {
            throw CuaDriverManagerError.invalidToolsListResponse
        }

        return RunningInfo(
            pid: pid,
            serverName: serverName,
            serverVersion: serverVersion,
            toolCount: tools.count
        )
    }

    private func response(id: Int, lines: CuaDriverLineInbox) async throws -> [String: Any] {
        try await withTimeout(.seconds(10)) {
            while true {
                guard let line = try await lines.nextLine() else {
                    throw CuaDriverManagerError.unexpectedEOF
                }
                let message = try Self.decodeJSONObject(line)
                if let responseID = message["id"] as? Int, responseID == id {
                    return message
                }
            }
        }
    }

    private func writeJSONObject(_ object: [String: Any], to input: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = Data(data)
        line.append(0x0A)
        try input.write(contentsOf: line)
    }

    private func withTimeout<T>(
        _ duration: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [clock] in
                // Bounded protocol/process deadline; this is not used for polling.
                try await clock.sleep(for: duration)
                throw CuaDriverManagerError.timeout
            }
            guard let result = try await group.next() else {
                throw CuaDriverManagerError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }

    private func terminateForAppTermination() {
        guard let session else { return }
        session.isStopping = true
        let process = session.process
        if process.isRunning {
            process.terminate()
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.session = nil
    }

    private func handleTermination(session terminatedSession: CuaDriverProcessSession?, status: Int32) async {
        guard let terminatedSession, session === terminatedSession else { return }
        await terminatedSession.terminationInbox.yield(status)
        if terminatedSession.isStopping {
            return
        }
        session = nil
        state = .failed(String(localized: "settings.computerUse.driver.status.exited", defaultValue: "cua-driver exited with status \(status)."))
    }

    private func yieldState(_ state: State) {
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    nonisolated private static func decodeJSONObject(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw CuaDriverManagerError.invalidUTF8
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CuaDriverManagerError.invalidJSON
        }
        return object
    }
}

private enum CuaDriverManagerError: LocalizedError {
    case timeout
    case unexpectedEOF
    case invalidUTF8
    case invalidJSON
    case invalidInitializeResponse
    case invalidToolsListResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            return String(localized: "settings.computerUse.driver.error.timeout", defaultValue: "Timed out waiting for cua-driver.")
        case .unexpectedEOF:
            return String(localized: "settings.computerUse.driver.error.eof", defaultValue: "cua-driver closed stdout before the handshake completed.")
        case .invalidUTF8:
            return String(localized: "settings.computerUse.driver.error.utf8", defaultValue: "cua-driver returned non-UTF-8 output.")
        case .invalidJSON:
            return String(localized: "settings.computerUse.driver.error.json", defaultValue: "cua-driver returned invalid JSON.")
        case .invalidInitializeResponse:
            return String(localized: "settings.computerUse.driver.error.initialize", defaultValue: "cua-driver returned an invalid initialize response.")
        case .invalidToolsListResponse:
            return String(localized: "settings.computerUse.driver.error.tools", defaultValue: "cua-driver returned an invalid tools/list response.")
        }
    }
}

// Process and pipe handles are touched from MainActor; the termination inbox is an actor.
private final class CuaDriverProcessSession: @unchecked Sendable {
    let process: Process
    let stdin: Pipe
    let terminationInbox = CuaDriverTerminationInbox()
    var stdoutDrainTask: Task<Void, Never>?
    var stderrDrainTask: Task<Void, Never>?
    var pid: Int32?
    var isStopping = false

    init(
        process: Process,
        stdin: Pipe,
        stdoutDrainTask: Task<Void, Never>?,
        stderrDrainTask: Task<Void, Never>?
    ) {
        self.process = process
        self.stdin = stdin
        self.stdoutDrainTask = stdoutDrainTask
        self.stderrDrainTask = stderrDrainTask
    }

    deinit {
        stdoutDrainTask?.cancel()
        stderrDrainTask?.cancel()
    }
}

private actor CuaDriverTerminationInbox {
    private var bufferedStatus: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func yield(_ status: Int32) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: status)
        } else {
            bufferedStatus = status
        }
    }

    func next() async throws -> Int32 {
        if let status = bufferedStatus {
            bufferedStatus = nil
            return status
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

// The handshake has exactly one stdout consumer; the timeout task only cancels it.
private final class CuaDriverLineInbox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.Iterator

    init(stream: AsyncThrowingStream<String, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func nextLine() async throws -> String? {
        try await iterator.next()
    }
}

private enum CuaDriverLineStream {
    static func lines(from fileHandle: FileHandle) -> AsyncThrowingStream<String, Error> {
        let fd = dup(fileHandle.fileDescriptor)
        return AsyncThrowingStream { continuation in
            guard fd >= 0 else {
                continuation.finish(throwing: POSIXError(.EBADF))
                return
            }
            let task = Task.detached(priority: .utility) {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var buffer = Data()
                do {
                    while !Task.isCancelled {
                        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if chunk.isEmpty {
                            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                                continuation.yield(line)
                            }
                            continuation.finish()
                            return
                        }
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[..<newline]
                            let next = buffer.index(after: newline)
                            buffer.removeSubrange(..<next)
                            if let line = String(data: lineData, encoding: .utf8) {
                                continuation.yield(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                            } else {
                                continuation.finish(throwing: CuaDriverManagerError.invalidUTF8)
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func drain(fileHandle: FileHandle) -> Task<Void, Never> {
        let fd = dup(fileHandle.fileDescriptor)
        return Task.detached(priority: .utility) {
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            while !Task.isCancelled {
                do {
                    let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                    if chunk.isEmpty { return }
                } catch {
                    return
                }
            }
        }
    }
}
