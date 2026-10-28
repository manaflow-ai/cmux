public import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import CmuxNextWakeups

/// One running `cmux-mobile-host` child: its stdout as event lines, its stdin for
/// control lines, its stderr appended to a log file. The spawn runs on a
/// ``ProcessLauncher`` queue and the child at its priority's `processQoS`; reading
/// happens on Foundation's pipe queue, never the caller's actor. The child exits by
/// itself when stdin closes, so a crash of the app ends it too.
public final class MobileHostProcess: Sendable {
    private struct State {
        var process: Process?
        var input: FileHandle?
        var exitStatus: Int32?
        /// stop() ran; a launch that finishes after it ends hostd at once.
        var stopped = false
        var exitWaiters: [OnceContinuation<Int32, OnceContinuationError>] = []
    }

    /// hostd's stdout lines (bounded: oldest dropped past 256 pending).
    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let state = Mutex(State())
    private let launcher: ProcessLauncher

    /// - Parameter launcher: spawns and stops hostd. The default runs both at ``WorkPriority/userVisible``:
    ///   hostd serves the person's phone now.
    public init(launcher: ProcessLauncher = ProcessLauncher(label: "com.cmuxterm.next.mobile-host", priority: .userVisible)) {
        self.launcher = launcher
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Starts `launch.executable` with `environment` and returns once it runs; stderr goes to `log`
    /// (created 0600) or nowhere.
    /// - Throws: the launch error.
    public func start(_ launch: MobileHostLaunch, environment: [String: String], log: URL?) async throws {
        let process = Process()
        process.executableURL = launch.executable
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Self.logHandle(log) ?? FileHandle.nullDevice
        // A write after hostd exited must fail with EPIPE, not raise SIGPIPE in the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let buffer = LineBuffer()
        let continuation = continuation
        output.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let waiters = self?.state.withLock { state -> [OnceContinuation<Int32, OnceContinuationError>] in
                state.exitStatus = status
                try? state.input?.close()
                state.input = nil
                defer { state.exitWaiters.removeAll() }
                return state.exitWaiters
            } ?? []
            for waiter in waiters { waiter.resume(returning: status) }
        }
        try await launcher.launched(process)
        // Stored only once hostd runs, so pid and send() never describe a child that did not start. A
        // stop() during the launch found nothing to end; hostd is ended here instead.
        let stoppedDuringLaunch = state.withLock { state -> Bool in
            state.process = process
            guard !state.stopped, state.exitStatus == nil else { return true }
            state.input = input.fileHandleForWriting
            return false
        }
        if stoppedDuringLaunch {
            try? input.fileHandleForWriting.close()
            launcher.terminate(process)
        }
    }

    /// Writes one control line; false when hostd is gone.
    @discardableResult
    public func send(_ line: Data) -> Bool {
        state.withLock { state in
            guard state.exitStatus == nil, let input = state.input else { return false }
            do {
                try input.blockingWrite(contentsOf: line)
                return true
            } catch {
                return false
            }
        }
    }

    public var pid: Int32? { state.withLock { $0.process?.processIdentifier } }

    /// What ``waitForExit()`` returns when its waiter was dropped without the exit status: the supervisor's
    /// "status unknown".
    public static let unknownExitStatus: Int32 = -1

    /// The child's exit status once it exited; ``unknownExitStatus`` when the wait was dropped unresumed.
    public func waitForExit() async -> Int32 {
        (try? await withOnceContinuation { (waiter: OnceContinuation<Int32, OnceContinuationError>) in
            let done = state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.exitWaiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }) ?? Self.unknownExitStatus
    }

    /// Closes stdin (hostd exits on its own) and sends SIGTERM, on the launcher's queue after the launch.
    public func stop() {
        let process = state.withLock { state -> Process? in
            state.stopped = true
            try? state.input?.close()
            state.input = nil
            return state.exitStatus == nil ? state.process : nil
        }
        if let process { launcher.terminate(process) }
    }

    /// The log file opened for appending, created with mode 0600 and
    /// started over once it passes 1 MB.
    static func logHandle(_ url: URL?) -> FileHandle? {
        guard let url else { return nil }
        let path = url.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 1 << 20 { try? FileManager.default.removeItem(atPath: path) }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle.blockingForWriting(to: URL(fileURLWithPath: path)) else { return nil }
        _ = try? handle.blockingSeekToEnd()
        return handle
    }
}

/// hostd's stdout split into lines; a line over 1 MB drops the buffer (hostd never writes one).
private final class LineBuffer: Sendable {
    private let splitter = Mutex(LineSplitter(maximumLineBytes: 1 << 20))

    func append(_ data: Data) -> [String] {
        splitter.withLock { splitter in
            do {
                return try splitter.append(data).map { String(decoding: $0, as: UTF8.self) }
            } catch {
                splitter = LineSplitter(maximumLineBytes: 1 << 20)
                return []
            }
        }
    }
}
