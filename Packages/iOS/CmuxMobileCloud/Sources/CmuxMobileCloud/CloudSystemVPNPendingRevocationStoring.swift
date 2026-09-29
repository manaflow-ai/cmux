/// Durable outbox for Cloud system VPN browser peers whose server revocation
/// did not complete before sign-out.
public protocol CloudSystemVPNPendingRevocationStoring: Sendable {
    /// Loads device fingerprints pending for one account and team scope.
    func load(scope: String) async -> Set<String>

    /// Replaces the pending fingerprints for one account and team scope.
    func save(_ fingerprints: Set<String>, scope: String) async
}
