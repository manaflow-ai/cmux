import Darwin
import Foundation

/// Synchronous coordination for Foundation process callbacks and teardown.
/// Safety: the condition confines every mutable field to the `Process` bridge;
/// no domain state crosses this synchronization boundary.
final class SimulatorWorkerProcessBox: @unchecked Sendable {
    private let condition = NSCondition()
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let terminationObservationTimeout: TimeInterval
    private let terminationGrace: Duration
    private let sleeper: any SimulatorWorkerSleeping
    private let workerProcessGroup = SimulatorWorkerProcessGroup()
    private var stopped = false
    private var terminationRequested = false
    private var terminationRecord: SimulatorWorkerTerminationRecord?
    private var failure: SimulatorFailure?
    private var forceKillTask: Task<Void, Never>?
    private var processIdentifier: Int32?
    private var processGroupWasKilled = false

    init(
        process: Process,
        stdin: Pipe,
        stdout: Pipe,
        terminationObservationTimeout: TimeInterval,
        terminationGrace: Duration,
        sleeper: any SimulatorWorkerSleeping
    ) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.terminationObservationTimeout = terminationObservationTimeout
        self.terminationGrace = terminationGrace
        self.sleeper = sleeper
    }

    deinit {
        forceKillTask?.cancel()
        process.terminationHandler = nil
        let processIdentifier = condition.withLock { () -> Int32? in
            guard !processGroupWasKilled else { return nil }
            processGroupWasKilled = true
            return self.processIdentifier
        }
        if let processIdentifier {
            _ = workerProcessGroup.signal(SIGKILL, groupIdentifier: processIdentifier)
            if process.isRunning, process.processIdentifier == processIdentifier {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        try? stdin.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
    }

    func installTerminationHandler() {
        process.terminationHandler = { [weak self] process in
            self?.recordTermination(
                reason: process.terminationReason,
                status: process.terminationStatus
            )
        }
    }

    func didLaunch(processIdentifier: Int32) {
        let shouldCleanExitedGroup = condition.withLock { () -> Bool in
            self.processIdentifier = processIdentifier > 1 ? processIdentifier : nil
            guard terminationRecord != nil,
                  self.processIdentifier != nil,
                  !processGroupWasKilled else { return false }
            processGroupWasKilled = true
            return true
        }
        if shouldCleanExitedGroup {
            _ = workerProcessGroup.signal(SIGKILL, groupIdentifier: processIdentifier)
        }
    }

    func launchFailed() {
        forceKillTask?.cancel()
        forceKillTask = nil
        process.terminationHandler = nil
    }

    func waitForTerminationAfterOutputEOF() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard terminationRecord == nil else { return true }
        guard terminationObservationTimeout > 0 else { return false }
        let deadline = Date(timeIntervalSinceNow: terminationObservationTimeout)
        while terminationRecord == nil, condition.wait(until: deadline) {}
        return terminationRecord != nil
    }

    func closeInput() {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return }
        stopped = true
        try? stdin.fileHandleForWriting.close()
    }

    func terminate() {
        condition.lock()
        guard !terminationRequested else {
            condition.unlock()
            return
        }
        terminationRequested = true
        let processIdentifier = self.processIdentifier ?? process.processIdentifier
        if process.isRunning {
            let sleeper = self.sleeper
            let grace = terminationGrace
            let task = Task { [self] in
                do {
                    // This bounded grace is the intended SIGTERM-to-SIGKILL deadline.
                    try await sleeper.sleep(for: grace)
                } catch {
                    return
                }
                forceKillIfRunning(processIdentifier: processIdentifier)
                completeForceKillDeadline()
            }
            forceKillTask = task
            let signalledGroup = workerProcessGroup.signal(
                SIGTERM,
                groupIdentifier: processIdentifier
            )
            if !signalledGroup { process.terminate() }
        }
        condition.unlock()
    }

    func failProtocolQueueOverflow() {
        condition.withLock {
            if failure == nil { failure = protocolQueueOverflowFailure() }
        }
        terminate()
    }

    func terminalFailure() -> SimulatorFailure? {
        condition.withLock {
            if let failure { return failure }
            guard terminationRecord?.reason == .exit,
                  terminationRecord?.status
                    == SimulatorLengthPrefixedMessageChannel.protocolQueueOverflowExitStatus
            else { return nil }
            return protocolQueueOverflowFailure()
        }
    }

    private func protocolQueueOverflowFailure() -> SimulatorFailure {
        SimulatorFailure(
            code: "worker_protocol_queue_overflow",
            message: String(
                localized: "simulator.failure.protocolQueueOverflow",
                defaultValue: "The Simulator protocol exceeded its bounded queue."
            ),
            isRecoverable: true
        )
    }

    private func forceKillIfRunning(processIdentifier: Int32) {
        let actions = condition.withLock { () -> (killGroup: Bool, killProcess: Bool) in
            let killGroup = self.processIdentifier == processIdentifier
                && !processGroupWasKilled
            if killGroup { processGroupWasKilled = true }
            let killProcess = process.isRunning
                && process.processIdentifier == processIdentifier
            return (killGroup, killProcess)
        }
        if actions.killGroup {
            _ = workerProcessGroup.signal(SIGKILL, groupIdentifier: processIdentifier)
        }
        if actions.killProcess { _ = Darwin.kill(processIdentifier, SIGKILL) }
    }

    private func completeForceKillDeadline() {
        condition.withLock { forceKillTask = nil }
    }

    private func recordTermination(
        reason: Process.TerminationReason,
        status: Int32
    ) {
        let cleanup = condition.withLock { () -> (Task<Void, Never>?, Int32?) in
            terminationRecord = SimulatorWorkerTerminationRecord(reason: reason, status: status)
            let task = forceKillTask
            forceKillTask = nil
            let groupIdentifier: Int32?
            if !processGroupWasKilled, processIdentifier != nil {
                processGroupWasKilled = true
                groupIdentifier = processIdentifier
            } else {
                groupIdentifier = nil
            }
            condition.broadcast()
            return (task, groupIdentifier)
        }
        cleanup.0?.cancel()
        if let groupIdentifier = cleanup.1 {
            _ = workerProcessGroup.signal(SIGKILL, groupIdentifier: groupIdentifier)
        }
    }
}
