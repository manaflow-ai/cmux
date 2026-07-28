import Darwin
import Foundation

/// One spawned helper process. All mutable state and callbacks are confined to
/// `queue`; the async API is only a continuation over this POSIX boundary.
final class CmuxConfigActionCatalogProcessSession:
    CmuxConfigActionCatalogQuarantinedProcess,
    @unchecked Sendable
{
    private let launch: CmuxConfigActionCatalogProcessReader.LaunchSpecification
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let maximumOutputBytes: Int
    private let timing: CmuxConfigActionCatalogProcessReader.Timing
    private let processOperations: CmuxConfigActionCatalogProcessReader.ProcessOperations
    private let quarantine: CmuxConfigActionCatalogProcessQuarantine
    private let quarantineLease: CmuxConfigActionCatalogProcessQuarantineLease
    private let quarantineAdmissionDelivery: @Sendable () async -> Void
    private let quarantineAdmissionCompletion: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.cmux.action-catalog-reader")
    private let reapQueue = DispatchQueue(
        label: "com.cmux.action-catalog-reader.reap",
        qos: .utility
    )

    private var continuation: CheckedContinuation<Result, Never>?
    private var processIdentifier: pid_t?
    private var stdoutFileDescriptor: Int32 = -1
    private var stdoutSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var timeoutTask: Task<Void, Never>?
    private var killTask: Task<Void, Never>?
    private var reapState = CmuxConfigActionCatalogProcessReapState.pending
    private var output = Data()
    private var outputOverflow = false
    private var pipeFailed = false
    private var cancellationRequested = false
    private var terminationReason: TerminationReason?
    private var handedOff = false
    private var quarantineAdmissionPending = false

    private var reapConfirmed: Bool {
        if case .confirmed = reapState { return true }
        return false
    }

    init(
        launch: CmuxConfigActionCatalogProcessReader.LaunchSpecification,
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        maximumOutputBytes: Int,
        timing: CmuxConfigActionCatalogProcessReader.Timing,
        processOperations: CmuxConfigActionCatalogProcessReader.ProcessOperations,
        quarantine: CmuxConfigActionCatalogProcessQuarantine,
        quarantineLease: CmuxConfigActionCatalogProcessQuarantineLease,
        quarantineAdmissionDelivery: @escaping @Sendable () async -> Void = {},
        quarantineAdmissionCompletion: @escaping @Sendable () -> Void = {}
    ) {
        self.launch = launch
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.maximumOutputBytes = maximumOutputBytes
        self.timing = timing
        self.processOperations = processOperations
        self.quarantine = quarantine
        self.quarantineLease = quarantineLease
        self.quarantineAdmissionDelivery = quarantineAdmissionDelivery
        self.quarantineAdmissionCompletion = quarantineAdmissionCompletion
        output.reserveCapacity(min(maximumOutputBytes, 64 << 10))
    }

    func run() async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    begin(continuation: continuation)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    nonisolated func cancel() {
        queue.async { [self] in
            cancellationRequested = true
            guard continuation != nil else { return }
            requestTermination(.cancelled)
        }
    }

    private func begin(continuation: CheckedContinuation<Result, Never>) {
        guard self.continuation == nil else {
            continuation.resume(returning: .completed(nil))
            return
        }
        self.continuation = continuation
        guard !cancellationRequested else {
            finish(returning: nil)
            return
        }
        guard spawnSuspendedProcess() else {
            finish(returning: nil)
            return
        }

        let timing = timing
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            do {
                try await timing.sleep(.seconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.enqueueTermination(.timedOut)
        }
        if let processIdentifier {
            processOperations.sendSignal(processIdentifier, SIGCONT, false)
        }
    }

    private func spawnSuspendedProcess() -> Bool {
        var outputFDs: [Int32] = [-1, -1]
        defer {
            for fileDescriptor in outputFDs where fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
            }
        }
        guard Darwin.pipe(&outputFDs) == 0,
              outputFDs.allSatisfy({ $0 > STDERR_FILENO }) else {
            return false
        }
        for fileDescriptor in outputFDs {
            guard fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        }
        let readFlags = fcntl(outputFDs[0], F_GETFL)
        guard readFlags >= 0,
              fcntl(outputFDs[0], F_SETFL, readFlags | O_NONBLOCK) == 0 else {
            return false
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var setupOK = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                $0,
                O_RDONLY,
                0
            ) == 0
        }
        setupOK = setupOK && posix_spawn_file_actions_adddup2(
            &fileActions,
            outputFDs[1],
            STDOUT_FILENO
        ) == 0
        setupOK = setupOK && "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                $0,
                O_WRONLY,
                0
            ) == 0
        }
        for fileDescriptor in outputFDs {
            setupOK = setupOK && posix_spawn_file_actions_addclose(
                &fileActions,
                fileDescriptor
            ) == 0
        }
        guard setupOK else { return false }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return false
        }

        let environment = launch.environment.keys.sorted().map {
            "\($0)=\(launch.environment[$0] ?? "")"
        }
        var spawnedPID: pid_t = 0
        let spawnStatus = withPOSIXCStringArray(launch.arguments) { arguments in
            withPOSIXCStringArray(environment) { environment in
                launch.executablePath.withCString { executablePath in
                    posix_spawn(
                        &spawnedPID,
                        executablePath,
                        &fileActions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }
        guard spawnStatus == 0 else { return false }

        Darwin.close(outputFDs[1])
        outputFDs[1] = -1
        processIdentifier = spawnedPID
        stdoutFileDescriptor = outputFDs[0]
        outputFDs[0] = -1
        installSources(processIdentifier: spawnedPID, stdoutFileDescriptor: stdoutFileDescriptor)
        return true
    }

    private func installSources(
        processIdentifier: pid_t,
        stdoutFileDescriptor: Int32
    ) {
        let stdoutSource = DispatchSource.makeReadSource(
            fileDescriptor: stdoutFileDescriptor,
            queue: queue
        )
        stdoutSource.setEventHandler { [weak self] in
            self?.drainStdout()
        }
        stdoutSource.setCancelHandler {
            Darwin.close(stdoutFileDescriptor)
        }
        self.stdoutSource = stdoutSource

        let processSource = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        processSource.setEventHandler { [weak self] in
            self?.processDidExit()
        }
        self.processSource = processSource
        stdoutSource.resume()
        processSource.resume()
    }

    private func drainStdout() {
        guard stdoutFileDescriptor >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(stdoutFileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                if output.count < maximumOutputBytes {
                    let keptCount = min(count, maximumOutputBytes - output.count)
                    output.append(contentsOf: chunk.prefix(keptCount))
                    if keptCount < count { outputOverflow = true }
                } else {
                    outputOverflow = true
                }
                if outputOverflow {
                    requestTermination(.outputOverflow)
                    closeStdout()
                    return
                }
            } else if count == 0 {
                closeStdout()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                pipeFailed = true
                requestTermination(.pipeFailure)
                closeStdout()
                return
            }
        }
    }

    private nonisolated func enqueueTermination(_ reason: TerminationReason) {
        queue.async { [weak self] in
            self?.requestTermination(reason)
        }
    }

    private func requestTermination(_ reason: TerminationReason) {
        if terminationReason == nil { terminationReason = reason }
        guard let processIdentifier, !reapConfirmed else {
            if self.processIdentifier == nil { finish(returning: nil) }
            return
        }
        signalProcessGroup(processIdentifier, signal: SIGTERM)
        guard killTask == nil else { return }
        let timing = timing
        let terminationGrace = terminationGrace
        killTask = Task { [weak self] in
            do {
                try await timing.sleep(.seconds(terminationGrace))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.enqueueForcedKill()
        }
    }

    private nonisolated func enqueueForcedKill() {
        queue.async { [weak self] in
            guard let self,
                  let processIdentifier = self.processIdentifier,
                  !self.reapConfirmed else {
                return
            }
            self.signalProcessGroup(processIdentifier, signal: SIGKILL)
            // One blocking wait is the authoritative post-kill lifecycle
            // signal. The caller may return after quarantine takes ownership,
            // but the lane remains held until this wait confirms the reap.
            self.startBlockingReap(processIdentifier: processIdentifier)
            self.handoffToQuarantineIfNeeded()
        }
    }

    private func handoffToQuarantineIfNeeded() {
        guard !reapConfirmed, !handedOff, continuation != nil,
              !quarantineAdmissionPending else { return }
        quarantineAdmissionPending = true
        let quarantine = quarantine
        let quarantineLease = quarantineLease
        Task { [weak self] in
            guard let self else { return }
            let accepted = await quarantine.quarantine(
                lease: quarantineLease,
                owner: self
            )
            if accepted { await self.quarantineAdmissionDelivery() }
            self.enqueueQuarantineAdmissionResult(accepted)
        }
    }

    private func enqueueQuarantineAdmissionResult(_ accepted: Bool) {
        queue.async { [weak self] in
            self?.completeQuarantineAdmission(accepted)
        }
    }

    private func completeQuarantineAdmission(_ accepted: Bool) {
        defer { quarantineAdmissionCompletion() }
        quarantineAdmissionPending = false
        guard accepted else {
            // Every spawned process reserved this slot before launch. Fail
            // closed if ownership was corrupted rather than dropping a child.
            if !reapConfirmed {
                assertionFailure("action catalog quarantine lease was lost")
            }
            return
        }
        guard !reapConfirmed, !handedOff, let continuation else {
            // A reaped non-handoff session completes with `.completed`; the
            // reader owns that reservation release exactly once. An existing
            // handoff is released only by its late-reap path below.
            return
        }
        handedOff = true
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        killTask?.cancel()
        killTask = nil
        closeStdout()
        continuation.resume(returning: .quarantined)
    }

    private func processDidExit() {
        guard let processIdentifier, !reapConfirmed else { return }
        // The leader is still an unreaped zombie, which pins the process-group
        // identity while descendants are terminated.
        signalProcessGroup(processIdentifier, signal: SIGTERM)
        signalProcessGroup(processIdentifier, signal: SIGKILL)
        guard case .pending = reapState else { return }

        let waitResult = processOperations.wait(processIdentifier, WNOHANG)
        if waitResult.processIdentifier == processIdentifier
            || (waitResult.processIdentifier == -1 && waitResult.errorNumber == ECHILD) {
            finishConfirmedReap(
                processIdentifier: processIdentifier,
                waitResult: waitResult
            )
            return
        }

        startBlockingReap(processIdentifier: processIdentifier)
    }

    private func startBlockingReap(processIdentifier: pid_t) {
        guard !reapConfirmed, case .pending = reapState else { return }
        reapState = .blocking
        let wait = processOperations.wait
        reapQueue.async { [self] in
            var waitResult = wait(processIdentifier, 0)
            while waitResult.processIdentifier == -1,
                  waitResult.errorNumber == EINTR {
                waitResult = wait(processIdentifier, 0)
            }
            let completedWaitResult = waitResult
            queue.async { [self] in
                blockingReapDidFinish(
                    processIdentifier: processIdentifier,
                    waitResult: completedWaitResult
                )
            }
        }
    }

    private func blockingReapDidFinish(
        processIdentifier: pid_t,
        waitResult: CmuxConfigActionCatalogProcessWaitResult
    ) {
        guard !reapConfirmed, self.processIdentifier == processIdentifier else { return }
        guard waitResult.processIdentifier == processIdentifier
                || (
                    waitResult.processIdentifier == -1
                        && waitResult.errorNumber == ECHILD
                ) else {
            // A result other than PID or ECHILD cannot prove that this child
            // was reaped. Keep its lease in the capacity-bounded quarantine.
            reapState = .unconfirmedFailure(waitResult)
            terminationReason = terminationReason ?? .pipeFailure
            handoffToQuarantineIfNeeded()
            return
        }
        finishConfirmedReap(
            processIdentifier: processIdentifier,
            waitResult: waitResult
        )
    }

    private func finishConfirmedReap(
        processIdentifier: pid_t,
        waitResult: CmuxConfigActionCatalogProcessWaitResult
    ) {
        guard !reapConfirmed, self.processIdentifier == processIdentifier else { return }
        let wasReapedByUs = waitResult.processIdentifier == processIdentifier
        reapState = .confirmed
        self.processIdentifier = nil
        processSource?.cancel()
        processSource = nil
        drainStdout()
        closeStdout()

        let exitedSuccessfully = wasReapedByUs
            && waitResult.status & 0x7f == 0
            && ((waitResult.status >> 8) & 0xff) == 0
        let result = terminationReason == nil
            && exitedSuccessfully
            && !outputOverflow
            && !pipeFailed ? output : nil
        finishAfterReap(returning: result)
    }

    private func signalProcessGroup(_ processIdentifier: pid_t, signal: Int32) {
        guard !reapConfirmed else { return }
        processOperations.sendSignal(processIdentifier, signal, true)
    }

    private func closeStdout() {
        if let stdoutSource {
            self.stdoutSource = nil
            stdoutFileDescriptor = -1
            stdoutSource.cancel()
        } else if stdoutFileDescriptor >= 0 {
            Darwin.close(stdoutFileDescriptor)
            stdoutFileDescriptor = -1
        }
    }

    private func finish(returning result: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        killTask?.cancel()
        killTask = nil
        processSource?.cancel()
        processSource = nil
        closeStdout()
        continuation.resume(returning: .completed(result))
    }

    private func finishAfterReap(returning result: Data?) {
        if handedOff {
            timeoutTask?.cancel()
            timeoutTask = nil
            killTask?.cancel()
            killTask = nil
            processSource?.cancel()
            processSource = nil
            closeStdout()
            let quarantine = quarantine
            let quarantineLease = quarantineLease
            Task { await quarantine.release(quarantineLease) }
        } else {
            finish(returning: result)
        }
    }
}

private func withPOSIXCStringArray<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
) -> T {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
