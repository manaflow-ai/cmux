public import Foundation
import CmuxNextWakeups

/// ``ProcessLaunching`` through `AsyncProcess`, the shared child-process path: the child gets its
/// input through a pipe that is written while it runs (any size), its output goes to read sources
/// (never the app's own streams), it runs on the caller's executor (the sender's actor, never the
/// main thread) until it exits or `timeout` passes, and it is killed at the deadline or when the
/// caller is cancelled. No thread waits for it.
public nonisolated struct ProcessLauncher: ProcessLaunching {
    private let timeout: Duration
    private let processes: AsyncProcess

    /// - Parameters:
    ///   - timeout: How long a child may run. `acpmux send --no-wait` exits once the daemon queued
    ///     the message: one status-socket round trip (the status client's deadline is 2 s) after the
    ///     CLI starts. 10 s covers a cold start of the CLI on a loaded Mac and bounds a daemon that
    ///     accepts and never answers (a handoff), so no send leaves a child behind.
    ///   - clock: The deadline's clock (tests pass their own).
    public init(timeout: Duration = .seconds(10), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        processes = AsyncProcess(clock: clock)
    }

    /// Runs `executable` to its exit or the deadline, with `input` on its stdin.
    public nonisolated func run(_ executable: URL, arguments: [String], environment: [String: String], input: Data? = nil) async -> Int32? {
        let request = ProcessRequest(executable, arguments, environment: environment, input: input, timeout: timeout, stopSignal: SIGKILL)
        guard let outcome = try? await processes.run(request), outcome.exited else {
            // Not started, killed at the deadline or by a signal: the caller reports the send as not sent.
            return nil
        }
        return outcome.status
    }
}
