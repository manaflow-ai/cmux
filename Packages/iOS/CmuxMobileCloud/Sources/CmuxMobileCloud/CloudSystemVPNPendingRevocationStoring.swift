/// Durable outbox for Cloud system VPN browser peers whose server revocation
/// did not complete before sign-out.
public struct CloudSystemVPNPendingRevocation: Hashable, Sendable {
    /// The device role whose browser peer still needs revocation.
    public let deviceFingerprint: String

    /// The team that owned the peer's captured credentials. `nil` is the
    /// personal-account context and also represents entries written by older
    /// builds before team identity was persisted.
    public let teamID: String?

    /// Creates a pending browser-peer revocation.
    public init(deviceFingerprint: String, teamID: String?) {
        self.deviceFingerprint = deviceFingerprint
        self.teamID = teamID
    }
}

public protocol CloudSystemVPNPendingRevocationStoring: Sendable {
    /// Loads pending browser-peer revocations for one account and team scope.
    func load(scope: String) async -> Set<CloudSystemVPNPendingRevocation>

    /// Replaces pending browser-peer revocations for one account and team scope.
    func save(
        _ revocations: Set<CloudSystemVPNPendingRevocation>,
        scope: String
    ) async
}
