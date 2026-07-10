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
    static let handshakeResponseTimeout: Duration = .seconds(10)
    private static let processTerminationTimeout: Duration = .seconds(3)
    private static let startWaitTimeout =
        handshakeResponseTimeout + handshakeResponseTimeout +
        handshakeResponseTimeout + handshakeResponseTimeout +
        processTerminationTimeout + processTerminationTimeout
    private static let skyCursorArguments = ["mcp", "--no-daemon-relaunch", "--cursor-shape", "sky"]
    private static let plainArguments = ["mcp", "--no-daemon-relaunch"]

    private(set) var state: State = .stopped {
        didSet { yieldState(state) }
    }

    @ObservationIgnored private let resolver: CuaDriverBinaryResolver
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var session: CuaDriverProcessSession?
    @ObservationIgnored private var activeStartID: UUID?
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

    func ensure(
        settingValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHelperURL: URL = CuaDriverBinaryResolver.bundleHelperURL(),
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) async -> RunningInfo? {
        switch state {
        case .running(let info):
            return info
        case .starting:
            guard let startID = activeStartID else {
                state = .stopped
                await start(
                    settingValue: settingValue,
                    environment: environment,
                    bundleHelperURL: bundleHelperURL,
                    fileExists: fileExists
                )
                guard case .running(let info) = state else { return nil }
                return info
            }
            return await runningInfoAfterCurrentStart(startID: startID)
        case .notFound, .stopped, .failed:
            await start(
                settingValue: settingValue,
                environment: environment,
                bundleHelperURL: bundleHelperURL,
                fileExists: fileExists
            )
            guard case .running(let info) = state else { return nil }
            return info
        }
    }

    private func runningInfoAfterCurrentStart(startID: UUID) async -> RunningInfo? {
        let updates = stateUpdates()
        do {
            return try await withTimeout(Self.startWaitTimeout) {
                for await update in updates {
                    switch update {
                    case .running(let info):
                        return info
                    case .notFound, .stopped, .failed:
                        return nil
                    case .starting:
                        continue
                    }
                }
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            guard activeStartID == startID, case .starting = state else { return nil }
            await stop()
            if activeStartID == startID, case .stopped = state {
                state = .failed(CuaDriverManagerError.timeout.localizedDescription)
            }
            return nil
        }
    }

    func start(
        settingValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleHelperURL: URL = CuaDriverBinaryResolver.bundleHelperURL(),
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) async {
        guard activeStartID == nil else { return }
        switch state {
        case .running:
            return
        case .starting:
            state = .stopped
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
        let startID = UUID()
        activeStartID = startID
        var terminalState: State = .stopped
        defer {
            if activeStartID == startID {
                activeStartID = nil
                if case .starting = state {
                    state = terminalState
                }
            }
        }

        let firstAttempt = await startResolvedDriver(
            resolution: resolution,
            arguments: Self.skyCursorArguments,
            environment: environment,
            retryWhenProcessExitsBeforeHandshake: true
        )
        let finalAttempt: CuaDriverStartAttemptResult
        if case .retryWithoutCursor = firstAttempt {
            guard activeStartID == startID, case .starting = state else { return }
            finalAttempt = await startResolvedDriver(
                resolution: resolution,
                arguments: Self.plainArguments,
                environment: environment,
                retryWhenProcessExitsBeforeHandshake: false
            )
        } else {
            finalAttempt = firstAttempt
        }

        switch finalAttempt {
        case .running:
            terminalState = .stopped
        case .retryWithoutCursor, .stopped:
            terminalState = .stopped
        case .failed(let message):
            terminalState = .failed(message)
        }
        if activeStartID == startID, case .starting = state {
            state = terminalState
        }
    }

    private func startResolvedDriver(
        resolution: CuaDriverBinaryResolution,
        arguments: [String],
        environment: [String: String],
        retryWhenProcessExitsBeforeHandshake: Bool
    ) async -> CuaDriverStartAttemptResult {
        let process = Process()
        process.executableURL = resolution.url
        process.arguments = arguments
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
            stderrDrainTask: CuaDriverLineStream.drain(fileHandle: stderr.fileHandleForReading),
            suppressTerminationFailureBeforeHandshake: retryWhenProcessExitsBeforeHandshake
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
            guard process.isRunning else {
                if runningSession.isStopping {
                    return .stopped
                }
                if self.session === runningSession {
                    self.session = nil
                }
                if retryWhenProcessExitsBeforeHandshake {
                    return .retryWithoutCursor
                }
                let message = Self.exitedStatusMessage(process.terminationStatus)
                state = .failed(message)
                return .failed(message)
            }
            guard self.session === runningSession else {
                return startAttemptResultAfterSessionLoss()
            }
            runningSession.suppressTerminationFailureBeforeHandshake = false
            runningSession.stdoutDrainTask = CuaDriverLineStream.drain(lines: lineInbox)
            state = .running(info)
            return .running
        } catch {
            if runningSession.isStopping {
                return .stopped
            }
            if self.session === runningSession {
                if retryWhenProcessExitsBeforeHandshake, !process.isRunning, !runningSession.isStopping {
                    self.session = nil
                    return .retryWithoutCursor
                }
                let message = error.localizedDescription
                await stopSession(runningSession, finalState: .failed(message))
                return .failed(message)
            }
            return startAttemptResultAfterSessionLoss()
        }
    }

    private func startAttemptResultAfterSessionLoss() -> CuaDriverStartAttemptResult {
        switch state {
        case .failed(let message):
            return .failed(message)
        case .starting:
            state = .stopped
            return .stopped
        case .notFound, .stopped, .running:
            return .stopped
        }
    }

    func stop() async {
        guard let session else {
            if case .notFound = state {
                state = .stopped
            } else if case .starting = state {
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
                _ = try await withTimeout(Self.processTerminationTimeout) {
                    try await terminationInbox.next()
                }
            } catch {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = try? await withTimeout(Self.processTerminationTimeout) {
                        try await terminationInbox.next()
                    }
                }
            }
        }

        if self.session === session {
            self.session = nil
            state = finalState
        }
    }

    func withTimeout<T>(
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
        terminatedSession.terminationInbox.yield(status)
        if terminatedSession.isStopping {
            return
        }
        if terminatedSession.suppressTerminationFailureBeforeHandshake {
            return
        }
        session = nil
        state = .failed(Self.exitedStatusMessage(status))
    }

    private static func exitedStatusMessage(_ status: Int32) -> String {
        String(localized: "settings.computerUse.driver.status.exited", defaultValue: "cua-driver exited with status \(status).")
    }

    private func yieldState(_ state: State) {
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

}

private enum CuaDriverStartAttemptResult {
    case running
    case retryWithoutCursor
    case stopped
    case failed(String)
}
