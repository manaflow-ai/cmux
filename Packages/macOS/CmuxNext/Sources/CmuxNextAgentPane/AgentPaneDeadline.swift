import Foundation

/// A cross-process step of the handshake missed its deadline
/// (architecture.md 5a: every cross-process call is async with a deadline).
nonisolated struct AgentPaneDeadlineExceeded: Error, Equatable, CustomStringConvertible {
    let label: String
    var description: String { "\(label) missed its deadline" }
}

/// Runs `operation`, cancelling it and throwing `AgentPaneDeadlineExceeded`
/// when it outlives `duration`. `onTimeout` then tears down work that does not
/// observe cancellation (a socket, a pipe read), before the group waits for it. A cancelled
/// caller runs `onTimeout` too, from the canceller's thread, so it must be safe to run there and
/// more than once (a connection's `cancel()` is).
///
/// `onTimeout` runs only once the deadline is the group's first result: the
/// teardown makes the operation fail (a cancelled socket reads as closed), and
/// run from the deadline's own task that failure could reach the group first
/// on a loaded machine, so a call that missed its deadline said `closed`
/// (job 122240111475: a hung acpmux's missed status call was not counted).
nonisolated func withAgentPaneDeadline<T: Sendable>(
    _ duration: Duration, label: String, onTimeout: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // A cancelled caller (the page's x on an upload whose call streams to a peer) tears the
    // operation down too: cancelling the group alone ends only the sleeper, and the group then
    // waits for a socket read that ignores cancellation, as long as the peer takes, or forever.
    try await withTaskCancellationHandler {
        // concurrency-allow: operations are cancellation-aware or torn down by onTimeout (socket cancel, pipe close)
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                // wakeup-allow: one-shot deadline (acpmux handshake)
                try await Task.sleep(for: duration)
                throw AgentPaneDeadlineExceeded(label: label)
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw AgentPaneDeadlineExceeded(label: label) }
                return first
            } catch let exceeded as AgentPaneDeadlineExceeded {
                onTimeout()
                throw exceeded
            }
        }
    } onCancel: {
        onTimeout()
    }
}
