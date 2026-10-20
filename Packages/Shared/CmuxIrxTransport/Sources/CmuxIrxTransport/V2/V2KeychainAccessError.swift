/// Errors returned by the small keychain seam used by v2 persistence.
public enum V2KeychainAccessError: Error, Equatable, Sendable {
    /// An item with the same service, account, and keychain domain already exists.
    case duplicate
    /// A Security framework operation failed with this status.
    case status(Int32)
}
