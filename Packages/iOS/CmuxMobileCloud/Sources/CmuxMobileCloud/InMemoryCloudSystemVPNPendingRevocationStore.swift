/// In-memory pending-revocation store for tests and previews.
public actor InMemoryCloudSystemVPNPendingRevocationStore:
    CloudSystemVPNPendingRevocationStoring
{
    private var fingerprintsByScope: [String: Set<String>] = [:]

    /// Creates an empty store.
    public init() {}

    /// Loads fingerprints pending for one account and team scope.
    public func load(scope: String) async -> Set<String> {
        fingerprintsByScope[scope] ?? []
    }

    /// Replaces pending fingerprints for one account and team scope.
    public func save(_ fingerprints: Set<String>, scope: String) async {
        if fingerprints.isEmpty {
            fingerprintsByScope.removeValue(forKey: scope)
        } else {
            fingerprintsByScope[scope] = fingerprints
        }
    }
}
