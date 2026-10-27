import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// A helper call or a `pmset` run took longer than its limit.
public nonisolated struct ServerHelperTimedOut: Error, Equatable {
    public nonisolated init() {}
}

/// Bounds a helper operation with an injected clock, without waiting for the
/// loser (the ControlDeadline pattern): the first of {result, deadline}
/// resumes the caller. On the deadline it runs `onTimeout` (kill the child,
/// invalidate the connection) and throws `ServerHelperTimedOut`; the
/// operation's late result is dropped. The deadline may fire up to
/// `tolerance` late: callers pass `WakeLeeway`'s for their limit (the helper's
/// runner, which links no CmuxNextWakeups, passes ``ProcessFixRunner/helperTolerance``).
public struct ServerHelperDeadline {
    public nonisolated init() {}
    public nonisolated func run<T: Sendable>(
        limit: Duration,
        tolerance: Duration,
        clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> T {
        let race = Race<T>()
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
            race.begin(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                // wakeup-allow: deadline of one helper request: the timer side of its result-or-deadline race; not a
                // DemandTimer, which the helper executable does not link
                // timer-class-allow: off-main in the server helper process, which has no main-thread scheduler (it links no CmuxNextWakeups)
                do { try await clock.sleep(for: limit, tolerance: tolerance) } catch { return }
                if race.finish(.failure(ServerHelperTimedOut())) {
                    onTimeout()
                    work.cancel()
                }
            }
            race.onFinish { timer.cancel() }
        }
    }

    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: OnceContinuation<T, any Error>?
            var done = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func begin(_ continuation: OnceContinuation<T, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        /// Registers cleanup; runs it now if the race already ended.
        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let runNow = state.withLock { state -> Bool in
                if state.done { return true }
                state.cleanup = cleanup
                return false
            }
            if runNow { cleanup() }
        }

        /// True for the first caller, which resumes the waiter.
        @discardableResult
        func finish(_ result: Result<T, any Error>) -> Bool {
            let (continuation, cleanup) = state.withLock { state -> (OnceContinuation<T, any Error>?, (@Sendable () -> Void)?) in
                guard !state.done else { return (nil, nil) }
                state.done = true
                defer {
                    state.continuation = nil
                    state.cleanup = nil
                }
                return (state.continuation, state.cleanup)
            }
            guard let continuation else { return false }
            continuation.resume(with: result)
            cleanup?()
            return true
        }
    }
}

/// One allowlisted child process, killable from the deadline.
///
/// The spawn runs on a dedicated utility thread, never the request's thread or Swift's cooperative pool
/// (Chromium's launcher thread, content/browser/child_process_launcher_helper.cc), and the child runs at
/// utility QoS too. The `Process` is made and configured on that thread and never leaves it, so this owner
/// holds only Sendable values; the deadline's ``kill()`` signals the pid the spawn recorded, and a kill that
/// comes before the spawn finished makes the spawn kill the child at once.
final nonisolated class FixChild: Sendable {
    /// Where the child is, as the spawn thread, the termination handler and the deadline see it.
    private struct Life {
        /// The child's pid from its spawn until its exit; 0 otherwise.
        var pid: pid_t = 0
        /// The deadline stopped this child.
        var stopped = false
        /// The child exited (its termination handler ran, which can be before the spawn thread records the pid).
        var ended = false
    }

    private let executable: URL
    private let arguments: [String]
    // concurrency-allow: the spawn thread, the termination handler and the deadline's kill meet on this pid and flag; each holds it for a field read or write (lock carve-out).
    private let life = Mutex(Life())

    init(_ executable: URL, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func start() async throws -> FixRunResult {
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<FixRunResult, any Error>) in
            Process.runOnOwnThread(qos: .utility, name: "com.cmuxterm.server-helper.fix",
                                   { [self] in makeProcess(reportingTo: continuation) },
                                   launched: { [self] pid in spawned(pid) },
                                   failed: { error in continuation.resume(throwing: error) })
        }
    }

    /// The configured child, made on the spawn thread: no shell, an empty environment, stdout to a pipe
    /// whose output the termination handler hands to `continuation`.
    private func makeProcess(reportingTo continuation: OnceContinuation<FixRunResult, any Error>) -> Process {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = pipe.fileHandleForReading
        process.terminationHandler = { [self] finished in
            life.withLock { $0.pid = 0; $0.ended = true }
            // concurrency-allow: Process.terminationHandler runs on a background queue, never the main thread; pmset -g custom prints about 1 KiB, far below the pipe buffer, so it never blocks the child before exit
            let data = (try? output.readToEnd()) ?? Data()
            continuation.resume(returning: FixRunResult(status: finished.terminationStatus, output: String(decoding: data.prefix(65_536), as: UTF8.self)))
        }
        return process
    }

    /// Kills only this child (the process the helper started): now when it runs, at its spawn when that has
    /// not finished yet, never after its exit (the pid may belong to another process by then).
    func kill() {
        let pid = life.withLock { life -> pid_t in
            life.stopped = true
            return life.ended ? 0 : life.pid
        }
        if pid > 0 { Darwin.kill(pid, SIGKILL) }
    }

    /// Records the spawned child's pid (on the spawn thread); kills it at once when the deadline already stopped it.
    private func spawned(_ pid: pid_t) {
        let stopped = life.withLock { life -> Bool in
            guard !life.ended else { return false }
            life.pid = pid
            return life.stopped
        }
        if stopped { Darwin.kill(pid, SIGKILL) }
    }
}
