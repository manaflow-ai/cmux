import Darwin
import Foundation
import Synchronization

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
/// sidecar removes its temporary patch), then SIGKILL after `grace`. Every
/// read runs on Foundation's pipe threads; nothing here blocks or polls.
nonisolated enum DiffSidecarProcess {
    static let readyMarker = Data("cmux-diff-sidecar-process-group-ready\n".utf8)
    static let maximumReply = 32 * 1024 * 1024

    struct Limits: Sendable {
        var startup: Duration = .seconds(5)
        /// Longer than the sidecar's 120-second session open limit.
        var request: Duration = .seconds(130)
        var grace: Duration = .milliseconds(250)
    }

    static func run(executable: URL, arguments: [String], request: Data, limits: Limits = Limits(),
                    clock: any Clock<Duration> = ContinuousClock()) async throws -> Data {
        let invocation = Invocation(request: request, grace: limits.grace, clock: clock)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    invocation.start(executable: executable, arguments: arguments, limits: limits, continuation: continuation)
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
        var reply = Data()
        var stderr = Data()
        var ready = false
        var replyClosed = false
        var exitStatus: Int32?
        var continuation: CheckedContinuation<Data, any Error>?
        var outcome: Result<Data, DiffSidecarError>?
        var deadlines: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let request: Data
    private let grace: Duration
    private let clock: any Clock<Duration>

    init(request: Data, grace: Duration, clock: any Clock<Duration>) {
        self.request = request
        self.grace = grace
        self.clock = clock
    }

    func start(executable: URL, arguments: [String], limits: DiffSidecarProcess.Limits,
               continuation: CheckedContinuation<Data, any Error>) {
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
            return false
        }
        if cancelled {
            resumeIfFinished(continuation)
            return
        }
        do {
            try process.run()
        } catch {
            fail(.startFailed)
            return
        }
        // A cancel that landed while the child launched found no pid to stop.
        if state.withLock({ $0.outcome != nil }) {
            stop(process, group: false)
            return
        }
        arm(after: limits.startup) { $0.ready ? nil : .startFailed }
        arm(after: limits.request) { _ in .timedOut }
    }

    /// Fails with `error` (unless already finished) and stops the child.
    func fail(_ error: DiffSidecarError) {
        let (continuation, process, ready) = state.withLock { state -> (CheckedContinuation<Data, any Error>?, Process?, Bool) in
            guard state.outcome == nil else { return (nil, nil, false) }
            state.outcome = .failure(error)
            for deadline in state.deadlines { deadline.cancel() }
            try? state.stdin?.close()
            state.stdin = nil
            return (state.continuation.take(), state.exitStatus == nil ? state.process : nil, state.ready)
        }
        continuation?.resume(throwing: error)
        if let process { stop(process, group: ready) }
    }

    private func arm(after delay: Duration, _ check: @escaping @Sendable (State) -> DiffSidecarError?) {
        let clock = clock
        let task = Task { [weak self] in
            // wakeup-allow: one-shot deadline (sidecar startup or reply)
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, let error = self.state.withLock({ check($0) }) else { return }
            self.fail(error)
        }
        state.withLock { $0.deadlines.append(task) }
    }

    private func receiveStderr(_ data: Data, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        let stdin = state.withLock { state -> FileHandle? in
            if state.stderr.count < 8192 { state.stderr.append(data) }
            guard !state.ready, state.stderr.starts(with: DiffSidecarProcess.readyMarker) else { return nil }
            state.ready = true
            defer { state.stdin = nil }
            return state.stdin
        }
        // The group exists now, so a stop reaches git and cmux children too.
        guard let stdin else { return }
        do {
            try stdin.write(contentsOf: request)
            try stdin.close()
        } catch {
            fail(.startFailed)
        }
    }

    private func receiveReply(_ data: Data, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            state.withLock { $0.replyClosed = true }
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
        let continuation = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            guard state.outcome == nil, state.replyClosed, let status = state.exitStatus else { return nil }
            for deadline in state.deadlines { deadline.cancel() }
            let valid = status == 0 && !state.reply.isEmpty && state.reply.count <= DiffSidecarProcess.maximumReply
            state.outcome = valid ? .success(state.reply) : .failure(.failed(status: status))
            return state.continuation.take()
        }
        if let continuation { resumeIfFinished(continuation) }
    }

    private func resumeIfFinished(_ continuation: CheckedContinuation<Data, any Error>) {
        guard let outcome = state.withLock({ $0.outcome }) else { return }
        continuation.resume(with: outcome)
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
            // wakeup-allow: one-shot deadline (SIGTERM grace)
            try? await clock.sleep(for: grace)
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
