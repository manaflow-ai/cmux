import Foundation

/// A deadline miss on a cross-process call (architecture.md 5a).
public struct DeadlineExceeded: Error, Sendable, CustomStringConvertible {
    public let label: String
    public var description: String { "\(label) missed its deadline" }
}

/// Runs `operation`, cancelling it and throwing `DeadlineExceeded` when it
/// outlives `duration`.
package func withDeadline<T: Sendable>(_ duration: Duration, label: String,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    // concurrency-allow: callers pass cancellation-aware work (URLSession, AsyncStream iteration)
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            // wakeup-allow: one-shot deadline (cross-process call)
            try await Task.sleep(for: duration)
            throw DeadlineExceeded(label: label)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded(label: label) }
        return first
    }
}
