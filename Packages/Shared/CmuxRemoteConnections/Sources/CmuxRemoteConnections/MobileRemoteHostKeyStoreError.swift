/// Failures from the account-scoped host-key trust store.
public enum MobileRemoteHostKeyStoreError: Error, Equatable, Sendable {
    /// The account namespace is malformed.
    case invalidAccount
    /// The trust file is corrupt, belongs to another account, or is unsupported.
    case corruptStore
    /// The store has reached its bounded observation limit.
    case capacityExceeded
}
