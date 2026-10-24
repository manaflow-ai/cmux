import Foundation

/// The names of the deadline actions that ran, in order, readable from the test without a hop to
/// the actor the actions ran on.
// Test-only recorder; `names` is guarded by `lock` (actions append on ManualActor, the test reads).
nonisolated final class RecordedRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var names: [String] { lock.withLock { recorded } }

    func append(_ name: String) {
        lock.withLock { recorded.append(name) }
    }
}
