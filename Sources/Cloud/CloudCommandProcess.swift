import Darwin
import Foundation

/// Owns command exit, output EOF, deadline and cancellation as one lifecycle.
actor CloudCommandProcess<DeadlineClock: Clock> where DeadlineClock.Duration == Duration {
    private let clock: DeadlineClock
    private var deadline: DeadlineClock.Instant?
    private var pid: pid_t?
    private var exited = false
    private var exitSource: DispatchSourceProcess?
    private var stdout: CloudCommandPipe?
    private var stderr: CloudCommandPipe?
    private var output: Data?
    private var diagnostic: Data?
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var deadlineTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var escalated = false

    init(clock: DeadlineClock) { self.clock = clock }

    func run(executable: URL, arguments: [String], input: Data?, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        if let input, input.count > 1_024 { throw CloudMachineLink.LinkError.inputTooLarge }
        guard timeout > .zero else { throw CloudMachineLink.LinkError.commandTimedOut }
        deadline = clock.now.advanced(by: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    try start(executable: executable, arguments: arguments, input: input)
                } catch {
                    self.continuation = nil
                    continuation.resume(throwing: CloudMachineLink.LinkError.spawnFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            Task { await self.stop(CancellationError()) }
        }
    }

    private func start(executable: URL, arguments: [String], input: Data?) throws {
        let child = try CloudCommandSpawn(executable: executable, arguments: arguments, input: input)
        pid = child.pid
        let stdout = CloudCommandPipe(descriptor: child.stdout)
        let stderr = CloudCommandPipe(descriptor: child.stderr)
        self.stdout = stdout
        self.stderr = stderr
        // kqueue observes exit without reaping. The zombie leader reserves its PID/PGID
        // until all group signals have been sent; no late signal can target a reused PID.
        let source = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: .global())
        source.setEventHandler { @Sendable [self] in Task { await didExit() } }
        exitSource = source
        source.activate()
        Task { didDrain(await stdout.read(), standardError: false) }
        Task { didDrain(await stderr.read(), standardError: true) }
        if let deadline {
            deadlineTask = Task {
                do { try await clock.sleep(until: deadline, tolerance: nil) } catch { return }
                stop(CloudMachineLink.LinkError.commandTimedOut)
            }
        }
        if Task.isCancelled {
            stop(CancellationError())
        } else if Darwin.kill(child.pid, SIGCONT) != 0 {
            stop(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func didExit() {
        exited = true
        completeIfReady()
    }

    private func didDrain(_ result: (data: Data, error: Int32?), standardError: Bool) {
        guard continuation != nil else { return }
        if standardError { diagnostic = result.data } else { output = result.data }
        if let error = result.error, failure == nil {
            stop(CloudMachineLink.LinkError.commandOutputFailed(error))
        }
        completeIfReady()
    }

    private func stop(_ error: any Error) {
        guard continuation != nil, failure == nil, let pid else { return }
        failure = error
        deadlineTask?.cancel()
        deadlineTask = nil
        _ = Darwin.kill(-pid, SIGTERM)
        // This is a termination grace, not retry/backoff. It is independent of the
        // cancelled caller and still escalates if TERM exits only the group leader.
        escalationTask = Task {
            do { try await ContinuousClock().sleep(for: .milliseconds(200)) } catch { return }
            forceStop()
        }
    }

    private func forceStop() {
        guard let pid, continuation != nil else { return }
        escalated = true
        _ = Darwin.kill(-pid, SIGKILL)
        stdout?.stop()
        stderr?.stop()
        // A kernel-stuck child cannot be reaped synchronously under a hard return bound.
        // Keep its exit source/identity alive for eventual reap and report cleanup failure.
        cleanupTask = Task {
            do { try await ContinuousClock().sleep(for: .seconds(1)) } catch { return }
            finish(throwing: CloudMachineLink.LinkError.commandCleanupFailed)
        }
        completeIfReady()
    }

    private func completeIfReady() {
        if continuation == nil {
            if exited { reap() }
            return
        }
        // On wake/resume, EOF may be delivered before the deadline task gets CPU.
        // Compare the actual monotonic deadline before accepting completion.
        if failure == nil, let deadline, clock.now >= deadline {
            stop(CloudMachineLink.LinkError.commandTimedOut)
        }
        guard exited, let output, let diagnostic, failure == nil || escalated else { return }
        if let pid { _ = Darwin.kill(-pid, SIGKILL) }
        let status = reap()
        if let failure {
            finish(throwing: failure)
        } else if let status, status == 0 {
            finish(returning: output)
        } else {
            let err = String(data: diagnostic, encoding: .utf8) ?? ""
            let out = String(data: output, encoding: .utf8) ?? ""
            finish(throwing: CloudMachineLink.LinkError.exited(status: status ?? -1, output: err.isEmpty ? out : err))
        }
    }

    /// Only called after the exit event: WNOHANG cannot block the actor/executor.
    @discardableResult
    private func reap() -> Int32? {
        guard exited, let pid else { return nil }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
        guard result != 0 else { return nil }
        self.pid = nil
        exitSource?.cancel()
        exitSource?.setEventHandler(handler: nil)
        exitSource = nil
        return result == pid ? (status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f) : nil
    }

    private func finish(returning output: Data) { finish(.success(output)) }
    private func finish(throwing error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if exited { reap() }
        deadlineTask?.cancel()
        escalationTask?.cancel()
        cleanupTask?.cancel()
        deadlineTask = nil
        escalationTask = nil
        cleanupTask = nil
        stdout = nil
        stderr = nil
        output = nil
        diagnostic = nil
        continuation.resume(with: result)
    }
}
