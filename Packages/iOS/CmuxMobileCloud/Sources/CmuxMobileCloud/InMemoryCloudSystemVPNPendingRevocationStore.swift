/// In-memory pending-revocation store for tests and previews.
public actor InMemoryCloudSystemVPNPendingRevocationStore:
    CloudSystemVPNPendingRevocationStoring
{
    private var revocationsByScope: [String: Set<CloudSystemVPNPendingRevocation>] = [:]

    /// Creates an empty store.
    public init() {}

    /// Loads pending browser-peer revocations for one account and team scope.
    public func load(scope: String) async -> Set<CloudSystemVPNPendingRevocation> {
        revocationsByScope[scope] ?? []
    }

    /// Replaces pending browser-peer revocations for one account and team scope.
    public func save(
        _ revocations: Set<CloudSystemVPNPendingRevocation>,
        scope: String
    ) async {
        if revocations.isEmpty {
            revocationsByScope.removeValue(forKey: scope)
        } else {
            revocationsByScope[scope] = revocations
        }
    }
}
