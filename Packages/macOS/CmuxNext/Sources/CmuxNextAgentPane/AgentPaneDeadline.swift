import Foundation
import CmuxNextWakeups

/// A cross-process step of the handshake missed its deadline
/// (architecture.md 5a: every cross-process call is async with a deadline).
nonisolated struct AgentPaneDeadlineExceeded: Error, Equatable, CustomStringConvertible {
    let label: String
    var description: String { "\(label) missed its deadline" }
}

/// Runs `operation`, cancelling it and throwing `AgentPaneDeadlineExceeded`
/// when it outlives `duration`. `onTimeout` runs first so work that does not
/// observe cancellation (a socket, a pipe read) can be torn down.
///
/// The race is ``Deadline``: the limit sleeps on `clock` with ``WakeLeeway``'s tolerance (a
/// flexible, no-sooner deadline, Chromium's `kFlexibleNoSooner`, base/task/delay_policy.h), and a
/// loser that ignores cancellation is dropped instead of awaited.
nonisolated func withAgentPaneDeadline<T: Sendable>(
    _ duration: Duration, label: String, clock: any Clock<Duration> = ContinuousClock(),
    onTimeout: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await Deadline(duration, clock: clock).run(label, onTimeout: onTimeout, operation)
    } catch is Deadline.Exceeded {
        throw AgentPaneDeadlineExceeded(label: label)
    }
}
