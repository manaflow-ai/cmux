/// The authoritative outcome of one machine destroy request.
public enum CloudMachineDeletionResult: Equatable, Sendable {
    /// The provider destroyed the machine.
    case deleted
    /// The provider no longer knows the machine; treat it as deleted.
    case notFound
    /// The machine may still exist; it must be listed again.
    case failed
}
