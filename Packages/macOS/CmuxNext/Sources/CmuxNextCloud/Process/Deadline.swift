import Foundation
import CmuxNextWakeups

/// A deadline miss on a cross-process call (architecture.md 5a).
public struct DeadlineExceeded: Error, Sendable, CustomStringConvertible {
    public let label: String
    public var description: String { "\(label) missed its deadline" }
}

/// Runs `operation`, cancelling it and throwing `DeadlineExceeded` when it
/// outlives `duration`. R-timer: a race's sleep is the `Deadline` helper's (flexible, never early, one ledger
/// wakeup per miss); a loser that ignores cancellation is dropped instead of awaited.
package func withDeadline<T: Sendable>(_ duration: Duration, label: String,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    do {
        return try await Deadline(duration).run(label, operation)
    } catch is Deadline.Exceeded {
        throw DeadlineExceeded(label: label)
    }
}
