import Darwin
import Foundation
import CmuxNextCompat
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// Why one sidecar request produced no reply.
nonisolated enum DiffSidecarError: Error, Equatable, Sendable {
    /// The bundled `bin/cmux-diff-sidecar` or `bin/cmux` is missing.
    case missingExecutable
    /// The child did not start, or did not report its process group in time.
    case startFailed
    /// No reply within the request deadline; the child was stopped.
    case timedOut
    /// The pool already has its limit running and its queue full.
    case busy
    /// The child exited non-zero, or its reply was empty or over the limit.
    case failed(status: Int32)
    /// The caller went away; the child was stopped.
    case cancelled
}

/// Runs one diff sidecar request on its own child process
/// (`cmux-diff-sidecar rpc ... --process-group-ready`), off the main actor, the
/// way the classic bridge did (DiffSidecarBridge, deleted in a4a0868db8b):
///
/// 1. start the child; it puts itself in a new process group and prints the
///    ready marker on stderr (within `startup`);
/// 2. write the request to stdin and close it;
/// 3. read stdout to EOF and wait for the exit; status 0 with a non-empty reply
///    of at most `maximumReply` bytes is the answer.
///
/// A missed deadline or a cancelled caller stops the whole group: SIGTERM (the
/// sidecar removes its temporary patch), then SIGKILL after `grace`. The spawn
/// runs on the launcher's queue at its priority, never on the caller's actor;
/// every read runs on Foundation's pipe threads; nothing here blocks or polls.
nonisolated enum DiffSidecarProcess {
    static let readyMarker = Data("cmux-diff-sidecar-process-group-ready\n".utf8)
    static let maximumReply = 32 * 1024 * 1024

    struct Limits: Sendable {
        var startup: Duration = .seconds(5)
        /// From the ready marker to the reply; longer than the sidecar's
        /// 120-second session open limit.
        var request: Duration = .seconds(130)
        var grace: Duration = .milliseconds(250)
    }

    static func run(executable: URL, arguments: [String], request: Data, launcher: ProcessLauncher, limits: Limits = Limits(),
                    clock: any Clock<Duration> = ContinuousClock()) async throws -> Data {
        let invocation = Invocation(request: request, grace: limits.grace, clock: clock)
        do {
            return try await withTaskCancellationHandler {
                try await withOnceThrowingContinuation { (continuation: OnceContinuation<Data, any Error>) in
                    invocation.start(executable: executable, arguments: arguments, launcher: launcher, limits: limits,
                                     continuation: continuation)
                }
            } onCancel: {
                invocation.fail(.cancelled)
            }
        } catch DiffSidecarError.cancelled {
            throw CancellationError()
        }
    }
}

/// The state of one child: what it wrote, whether it exited, and the caller's
/// continuation, resumed exactly once.
private nonisolated final class Invocation: Sendable {
    private struct State {
        var process: Process?
        var stdin: FileHandle?
        /// The parent's read ends, held until each reads end of file. The
        /// Process is released at exit, and with it the Pipes; a FileHandle
        /// that dies first closes its descriptor and drops the EOF event, so
        /// a reply that trailed the exit never finished (a 60 s test hang).
        var replyReader: FileHandle?
        var stderrReader: FileHandle?
        var reply = Data()
        var stderr = Data()
        var ready = false
        /// The request deadline, armed at the ready marker: a loaded machine
        /// can take longer than it to start the child, which `startup` judges.
        var requestLimit: Duration?
        var replyClosed = false
        var exitStatus: Int32?
        var continuation: OnceContinuation<Data, any Error>?
        var outcome: Result<Data, DiffSidecarError>?
    }

    private let state = Mutex(State())
    private let request: Data
    private let grace: Duration
    private let clock: any Clock<Duration>
    /// The child's `startup` bound, then its `request` bound from the ready marker; the outcome cancels both.
    private let startup: DemandTimer
    private let reply: DemandTimer

    init(request: Data, grace: Duration, clock: any Clock<Duration>) {
        self.request = request
        self.grace = grace
        self.clock = clock
        // timer-class-allow: off-main: the child's startup and reply bounds live in this nonisolated Invocation and only end it under its lock (the clock is the suites' seam); they post no main-thread job
        startup = DemandTimer(owner: "DiffSidecar.startup", clock: clock)
        // timer-class-allow: off-main: as the startup bound above
        reply = DemandTimer(owner: "DiffSidecar.reply", clock: clock)
    }

    func start(executable: URL, arguments: [String], launcher: ProcessLauncher, limits: DiffSidecarProcess.Limits,
               continuation: OnceContinuation<Data, any Error>) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            receiveReply(handle.availableData, handle: handle)
        }
        errors.fileHandleForReading.readabilityHandler = { [self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            receiveStderr(handle.availableData, handle: handle)
        }
        process.terminationHandler = { [self] finished in exited(finished.terminationStatus) }
        let cancelled = state.withLock { state -> Bool in
            if state.outcome != nil { return true }
            state.continuation = continuation
            state.process = process
            state.stdin = input.fileHandleForWriting
            state.replyReader = output.fileHandleForReading
            state.stderrReader = errors.fileHandleForReading
            state.requestLimit = limits.request
            return false
        }
        if cancelled {
            resumeIfFinished(continuation)
            return
        }
        let startupLimit = limits.startup
        launcher.launch(process, started: { [self] in launched(within: startupLimit) }, failed: { [self] _ in launchFailed() })
    }

    /// The child runs: its startup deadline starts, unless a cancel came during the launch.
    private func launched(within startupLimit: Duration) {
        // A cancel that landed while the child launched found no pid to stop.
        let (cancelled, process) = state.withLock { state -> (Bool, Process?) in (state.outcome != nil, state.process) }
        guard !cancelled else {
            if let process { stop(process, group: false) }
            return
        }
        arm(startup, after: startupLimit) { $0.ready ? nil : .startFailed }
    }

    /// No child holds a write end, so no EOF comes: release the readers here.
    private func launchFailed() {
        let readers = state.withLock { state -> [FileHandle] in
            defer {
                state.replyReader = nil
                state.stderrReader = nil
                state.process = nil
            }
            return [state.replyReader, state.stderrReader].compactMap { $0 }
        }
        for reader in readers { reader.readabilityHandler = nil }
        fail(.startFailed)
    }

    /// Fails with `error` (unless already finished) and stops the child.
    func fail(_ error: DiffSidecarError) {
        let (continuation, process, ready) = state.withLock { state -> (OnceContinuation<Data, any Error>?, Process?, Bool) in
            guard state.outcome == nil else { return (nil, nil, false) }
            state.outcome = .failure(error)
            try? state.stdin?.close()
            state.stdin = nil
            return (state.continuation.take(), state.exitStatus == nil ? state.process : nil, state.ready)
        }
        cancelDeadlines()
        continuation?.resume(throwing: error)
        if let process { stop(process, group: ready) }
    }

    /// Fails with `check`'s error when `timer` fires first; an outcome reached before or after the arm
    /// cancels it (``cancelDeadlines()``).
    private func arm(_ timer: DemandTimer, after delay: Duration, _ check: @escaping @Sendable (State) -> DiffSidecarError?) {
        timer.schedule(after: delay) { [weak self] in
            guard let self, let error = self.state.withLock({ check($0) }) else { return }
            self.fail(error)
        }
        if state.withLock({ $0.outcome != nil }) { timer.cancel() }
    }

    private func cancelDeadlines() {
        startup.cancel()
        reply.cancel()
    }

    private func receiveStderr(_ data: Data, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            state.withLock { $0.stderrReader = nil }
            return
        }
        let (stdin, requestLimit) = state.withLock { state -> (FileHandle?, Duration?) in
            if state.stderr.count < 8192 { state.stderr.append(data) }
            guard !state.ready, state.stderr.starts(with: DiffSidecarProcess.readyMarker) else { return (nil, nil) }
            state.ready = true
            defer { state.stdin = nil }
            return (state.stdin, state.requestLimit)
        }
        if let requestLimit {
            startup.cancel()
            arm(reply, after: requestLimit) { _ in .timedOut }
        }
        // The group exists now, so a stop reaches git and cmux children too.
        guard let stdin else { return }
        do {
            try stdin.blockingWrite(contentsOf: request)
            try stdin.close()
        } catch {
            fail(.startFailed)
        }
    }

    private func receiveReply(_ data: Data, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            state.withLock { state in
                state.replyClosed = true
                state.replyReader = nil
            }
            finishIfDone()
            return
        }
        let overflow = state.withLock { state -> Bool in
            state.reply.append(data)
            return state.reply.count > DiffSidecarProcess.maximumReply
        }
        if overflow { fail(.failed(status: 0)) }
    }

    private func exited(_ status: Int32) {
        state.withLock { state in
            state.exitStatus = status
            state.process = nil
        }
        finishIfDone()
    }

    private func finishIfDone() {
        let (finished, continuation) = state.withLock { state -> (Bool, OnceContinuation<Data, any Error>?) in
            guard state.outcome == nil, state.replyClosed, let status = state.exitStatus else { return (false, nil) }
            let valid = status == 0 && !state.reply.isEmpty && state.reply.count <= DiffSidecarProcess.maximumReply
            state.outcome = valid ? .success(state.reply) : .failure(.failed(status: status))
            return (true, state.continuation.take())
        }
        if finished { cancelDeadlines() }
        if let continuation { resumeIfFinished(continuation) }
    }

    private func resumeIfFinished(_ continuation: OnceContinuation<Data, any Error>) {
        guard let outcome = state.withLock({ $0.outcome }) else { return }
        continuation.resume(with: outcome.mapError { $0 })
    }

    /// SIGTERM to the child's group (or the child, before it made one), then
    /// SIGKILL when it is still running after the grace period.
    private func stop(_ process: Process, group: Bool) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let target = group && getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        let clock = clock, grace = grace
        // task-owner: one-shot escalation for a child that ignores SIGTERM; ends after `grace`
        Task { [self] in
            // wakeup-allow: deadline of the SIGTERM grace before SIGKILL; not a DemandTimer: it must outlive
            // the request that stopped the child, and nothing replaces or cancels it
            // timer-class-allow: off-main: this nonisolated Invocation's one grace before SIGKILL; it posts no main-thread job
            try? await clock.sleep(for: grace, tolerance: WakeLeeway.window(delay: grace).tolerance)
            guard state.withLock({ $0.exitStatus == nil }) else { return }
            kill(target, SIGKILL)
        }
    }
}

private extension Optional {
    /// The value, leaving nil behind.
    nonisolated mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
