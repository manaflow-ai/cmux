/// A typed event delivered by an active topology subscription.
public enum TopologyStreamEvent: Equatable, Sendable {
    /// One contiguous committed topology transaction.
    case delta(TopologyDelta)

    /// An instruction to discard local topology and request a new snapshot.
    case resnapshotRequired(BackendResnapshotRequired)
}
