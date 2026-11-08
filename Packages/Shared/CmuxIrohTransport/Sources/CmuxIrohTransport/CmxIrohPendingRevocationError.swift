/// Failures at the device-local pending-revocation boundary.
public enum CmxIrohPendingRevocationError: Error, Equatable, Sendable {
    /// A binding, account, or build-tag scope is malformed.
    case invalidRecord

    /// Persisted state is corrupt, mismatched, or from an unsupported schema.
    case invalidStoredState

    /// The bounded account outbox cannot accept another distinct binding.
    case capacityExceeded
}
