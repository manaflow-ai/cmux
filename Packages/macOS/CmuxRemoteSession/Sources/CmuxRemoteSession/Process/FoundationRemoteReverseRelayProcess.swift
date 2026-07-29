internal import Darwin
internal import Foundation

/// Foundation-backed handle for one dedicated SSH reverse-relay process.
///
/// `Process` and `Pipe` callbacks cross executor boundaries; all mutation is
/// protected by the capture state's lock while the coordinator serializes its
/// handle access.
final class FoundationRemoteReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    private let process: Process
    private let stderrPipe: Pipe
    private let stderrDrainGracePeriod: TimeInterval
    private let terminationGracePeriod: TimeInterval

    init(
        process: Process,
        stderrPipe: Pipe,
        stderrDrainGracePeriod: TimeInterval = 0.5,
        terminationGracePeriod: TimeInterval = 2
    ) {
        self.process = process
        self.stderrPipe = stderrPipe
        self.stderrDrainGracePeriod = stderrDrainGracePeriod
        self.terminationGracePeriod = terminationGracePeriod
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    /// Drains stderr without parking one utility worker for the relay's
    /// lifetime. EOF completes immediately after termination; an inherited
    /// writer that outlives ssh is cut off after a bounded final grace period.
    func captureTermination(
        _ handler: @escaping @Sendable (String?) -> Void
    ) {
        installLifecycleCapture(
            startupMarker: nil,
            startupHandler: nil,
            terminationHandler: handler
        )
    }

    /// Reports exact forward confirmation and eventual process termination
    /// from the same event-driven stderr stream.
    func captureLifecycle(
        startupMarker: String,
        startupTimeout: TimeInterval,
        startupHandler: @escaping @Sendable () -> Void,
        terminationHandler: @escaping @Sendable (String?) -> Void
    ) {
        installLifecycleCapture(
            startupMarker: startupMarker,
            startupTimeout: startupTimeout,
            startupTimeoutHandler: { [weak self] in
                self?.terminate()
            },
            startupHandler: startupHandler,
            terminationHandler: terminationHandler
        )
    }

    private func installLifecycleCapture(
        startupMarker: String?,
        startupTimeout: TimeInterval? = nil,
        startupTimeoutHandler: (@Sendable () -> Void)? = nil,
        startupHandler: (@Sendable () -> Void)?,
        terminationHandler: @escaping @Sendable (String?) -> Void
    ) {
        let readHandle = stderrPipe.fileHandleForReading
        let capture = ReverseRelayStderrCapture(
            readHandle: readHandle,
            drainGracePeriod: stderrDrainGracePeriod,
            startupMarker: startupMarker,
            startupTimeout: startupTimeout,
            startupTimeoutHandler: startupTimeoutHandler,
            startupHandler: startupHandler,
            terminationHandler: terminationHandler
        )
        readHandle.readabilityHandler = { handle in
            capture.receive(handle.availableData)
        }
        process.terminationHandler = { terminatedProcess in
            capture.processDidTerminate(status: terminatedProcess.terminationStatus)
        }
        if !process.isRunning {
            capture.processDidTerminate(status: process.terminationStatus)
        }
        capture.startStartupDeadline()
    }

    func terminate() {
        guard process.isRunning else { return }
        let process = process
        let processID = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, terminationGracePeriod)
        ) {
            guard process.isRunning,
                  process.processIdentifier == processID else {
                return
            }
            _ = Darwin.kill(processID, SIGKILL)
        }
    }
}

/// Event-driven stderr tail with a bounded post-termination drain.
private final class ReverseRelayStderrCapture: @unchecked Sendable {
    private struct Completion {
        let stderr: String
        let status: Int32
    }

    // lint:allow lock - FileHandle and Process callbacks are synchronous; the
    // critical sections only append bounded data and update lifecycle bits.
    private let lock = NSLock()
    private let readHandle: FileHandle
    private let startupMarker: Data?
    private let startupTimeout: TimeInterval?
    private let startupTimeoutHandler: (@Sendable () -> Void)?
    private let startupHandler: (@Sendable () -> Void)?
    private let terminationHandler: @Sendable (String?) -> Void
    private let byteLimit: Int
    private let drainGracePeriod: TimeInterval
    private var tail = Data()
    private var startupReported = false
    private var startupExpired = false
    private var sawEOF = false
    private var terminationStatus: Int32?
    private var drainDeadlineScheduled = false
    private var completed = false

    init(
        readHandle: FileHandle,
        byteLimit: Int = 8192,
        drainGracePeriod: TimeInterval,
        startupMarker: String?,
        startupTimeout: TimeInterval?,
        startupTimeoutHandler: (@Sendable () -> Void)?,
        startupHandler: (@Sendable () -> Void)?,
        terminationHandler: @escaping @Sendable (String?) -> Void
    ) {
        self.readHandle = readHandle
        self.byteLimit = byteLimit
        self.drainGracePeriod = drainGracePeriod
        self.startupMarker = startupMarker?.data(using: .utf8)
        self.startupTimeout = startupTimeout
        self.startupTimeoutHandler = startupTimeoutHandler
        self.startupHandler = startupHandler
        self.terminationHandler = terminationHandler
    }

    func startStartupDeadline() {
        guard let startupTimeout else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, startupTimeout)
        ) { [weak self] in
            self?.startupDeadlineElapsed()
        }
    }

    func receive(_ data: Data) {
        let result = lock.withLock { () -> (
            completion: Completion?,
            reportStartup: Bool
        ) in
            if data.isEmpty {
                sawEOF = true
            } else {
                tail.append(data)
                let reportStartup =
                    !completed &&
                    !startupReported &&
                    !startupExpired &&
                    startupMarker.map { tail.range(of: $0) != nil } == true
                if reportStartup {
                    startupReported = true
                }
                if tail.count > byteLimit {
                    tail.removeFirst(tail.count - byteLimit)
                }
                return (takeCompletionIfReady(), reportStartup)
            }
            return (takeCompletionIfReady(), false)
        }
        if result.reportStartup {
            startupHandler?()
        }
        finish(result.completion)
    }

    func processDidTerminate(status: Int32) {
        let result = lock.withLock { () -> (
            completion: Completion?,
            scheduleDeadline: Bool
        ) in
            terminationStatus = status
            let completion = takeCompletionIfReady()
            if let completion {
                return (completion, false)
            }
            guard !drainDeadlineScheduled else {
                return (nil, false)
            }
            drainDeadlineScheduled = true
            return (nil, true)
        }
        finish(result.completion)
        if result.scheduleDeadline {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, drainGracePeriod)
            ) { [self] in
                drainDeadlineElapsed()
            }
        }
    }

    private func drainDeadlineElapsed() {
        let completion = lock.withLock {
            takeCompletionIfReady(force: true)
        }
        finish(completion)
    }

    private func startupDeadlineElapsed() {
        let shouldTerminate = lock.withLock {
            guard !startupReported,
                  !startupExpired,
                  !completed,
                  terminationStatus == nil else {
                return false
            }
            startupExpired = true
            return true
        }
        if shouldTerminate {
            startupTimeoutHandler?()
        }
    }

    private func takeCompletionIfReady(force: Bool = false) -> Completion? {
        guard !completed,
              (sawEOF || force),
              let terminationStatus else {
            return nil
        }
        completed = true
        return Completion(
            stderr: String(data: tail, encoding: .utf8) ?? "",
            status: terminationStatus
        )
    }

    private func finish(_ completion: Completion?) {
        guard let completion else { return }
        readHandle.readabilityHandler = nil
        try? readHandle.close()
        terminationHandler(
            Self.preferredTerminationDetail(stderr: completion.stderr)
                ?? "status=\(completion.status)"
        )
    }

    private static func preferredTerminationDetail(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let forwardFailure = lines.last(where: {
            $0.localizedCaseInsensitiveContains(
                "remote port forwarding failed for listen"
            )
        }) {
            return forwardFailure
        }
        return RemoteSessionCoordinator.bestErrorLine(stderr: stderr)
    }
}
