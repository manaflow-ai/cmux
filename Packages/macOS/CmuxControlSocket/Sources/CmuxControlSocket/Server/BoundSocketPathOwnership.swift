/// Ownership proof for a pathname created by `bind(2)`.
enum BoundSocketPathOwnership: Equatable, Sendable {
    case none
    /// `bind(2)` succeeded while the immediate `lstat(2)` failed. The server
    /// retains both the bound descriptor and path lock until a later identity
    /// capture or safe teardown.
    case identityPending
    case identified(SocketPathIdentity)

    var identity: SocketPathIdentity? {
        guard case .identified(let identity) = self else { return nil }
        return identity
    }
}
