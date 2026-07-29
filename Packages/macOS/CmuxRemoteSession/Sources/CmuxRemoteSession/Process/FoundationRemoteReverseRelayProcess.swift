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

    init(
        process: Process,
        stderrPipe: Pipe,
        stderrDrainGracePeriod: TimeInterval = 0.5
    ) {
        self.process = process
        self.stderrPipe = stderrPipe
        self.stderrDrainGracePeriod = stderrDrainGracePeriod
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
        let readHandle = stderrPipe.fileHandleForReading
        let capture = ReverseRelayStderrCapture(
            readHandle: readHandle,
            drainGracePeriod: stderrDrainGracePeriod,
            handler: handler
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
    }

    func terminate() {
        process.terminate()
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
    private let handler: @Sendable (String?) -> Void
    private let byteLimit: Int
    private let drainGracePeriod: TimeInterval
    private var tail = Data()
    private var sawEOF = false
    private var terminationStatus: Int32?
    private var drainDeadlineScheduled = false
    private var completed = false

    init(
        readHandle: FileHandle,
        byteLimit: Int = 8192,
        drainGracePeriod: TimeInterval,
        handler: @escaping @Sendable (String?) -> Void
    ) {
        self.readHandle = readHandle
        self.byteLimit = byteLimit
        self.drainGracePeriod = drainGracePeriod
        self.handler = handler
    }

    func receive(_ data: Data) {
        let completion = lock.withLock { () -> Completion? in
            if data.isEmpty {
                sawEOF = true
            } else {
                tail.append(data)
                if tail.count > byteLimit {
                    tail.removeFirst(tail.count - byteLimit)
                }
            }
            return takeCompletionIfReady()
        }
        finish(completion)
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
        handler(
            RemoteSessionCoordinator.bestErrorLine(stderr: completion.stderr)
                ?? "status=\(completion.status)"
        )
    }
}
