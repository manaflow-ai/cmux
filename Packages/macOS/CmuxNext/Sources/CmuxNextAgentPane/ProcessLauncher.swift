public import Foundation
import CmuxNextDaemon

/// ``ProcessLaunching`` through `ProcessRunner`, the shared child-process path: the child gets the
/// null device as stdin and temp files as stdout and stderr (never the app's own streams), runs on
/// the caller's executor (the sender's actor, never the main thread) until it exits or `timeout`
/// passes, and is killed at the deadline or when the caller is cancelled.
public nonisolated struct ProcessLauncher: ProcessLaunching {
    private let timeout: Duration
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - timeout: How long a child may run. `acpmux send --no-wait` exits once the daemon queued
    ///     the message: one status-socket round trip (the status client's deadline is 2 s) after the
    ///     CLI starts. 10 s covers a cold start of the CLI on a loaded Mac and bounds a daemon that
    ///     accepts and never answers (a handoff), so no send leaves a child behind.
    ///   - clock: The deadline's clock (tests pass their own).
    public init(timeout: Duration = .seconds(10), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// Runs `executable` to its exit or the deadline.
    public nonisolated func run(_ executable: URL, arguments: [String], environment: [String: String]) async -> Int32? {
        do {
            return try await ProcessRunner.run(executable: executable, arguments: arguments, environment: environment,
                                               timeout: timeout, clock: clock).status
        } catch {
            // Not started, or killed at the deadline: the caller reports the send as not sent.
            return nil
        }
    }
}
