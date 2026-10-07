import Foundation

/// A cross-process step of the handshake missed its deadline
/// (architecture.md 5a: every cross-process call is async with a deadline).
nonisolated struct AgentPaneDeadlineExceeded: Error, Equatable, CustomStringConvertible {
    let label: String
    var description: String { "\(label) missed its deadline" }
}

/// Runs `operation`, cancelling it and throwing `AgentPaneDeadlineExceeded`
/// when it outlives `duration`. `onTimeout` runs first so work that does not
/// observe cancellation (a socket, a pipe read) can be torn down.
nonisolated func withAgentPaneDeadline<T: Sendable>(
    _ duration: Duration, label: String, onTimeout: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // concurrency-allow: operations are cancellation-aware or torn down by onTimeout (socket cancel, pipe close)
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            // wakeup-allow: one-shot deadline (acpmux handshake)
            try await Task.sleep(for: duration)
            onTimeout()
            throw AgentPaneDeadlineExceeded(label: label)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw AgentPaneDeadlineExceeded(label: label) }
        return first
    }
}
