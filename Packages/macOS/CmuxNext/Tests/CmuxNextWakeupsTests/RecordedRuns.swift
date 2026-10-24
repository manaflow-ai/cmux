import CmuxNextCompat

/// The names of the deadline actions that ran, in order, readable from the test without a hop to
/// the actor the actions ran on (actions append on ManualActor, the test reads).
final class RecordedRuns: Sendable {
    private let recorded = Mutex<[String]>([])

    var names: [String] { recorded.withLock { $0 } }

    func append(_ name: String) {
        recorded.withLock { $0.append(name) }
    }
}
