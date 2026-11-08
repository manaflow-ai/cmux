/// A verified, bounded catalog of managed Iroh relays.
public struct CmxIrohManagedRelayPolicy: Equatable, Sendable {
    /// Policy schema version.
    public let version: Int

    /// Canonical UUID identifying this signed policy publication.
    public let policyID: String

    /// Monotonic server sequence used for rollback protection.
    public let sequence: Int64

    /// Unix time when the policy was issued.
    public let issuedAt: Int64

    /// Unix time before which the policy must not be used.
    public let notBefore: Int64

    /// Unix time after which the policy must not be used.
    public let expiresAt: Int64

    /// Application audience restricting where the policy is accepted.
    public let audience: String

    /// Relay wire protocol implemented by every descriptor in this policy.
    public let relayProtocol: String

    /// Ordered managed relay catalog from which local selection is resolved.
    public let relays: [CmxIrohManagedRelayDescriptor]

    init(
        version: Int,
        policyID: String,
        sequence: Int64,
        issuedAt: Int64,
        notBefore: Int64,
        expiresAt: Int64,
        audience: String,
        relayProtocol: String,
        relays: [CmxIrohManagedRelayDescriptor]
    ) {
        self.version = version
        self.policyID = policyID
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.notBefore = notBefore
        self.expiresAt = expiresAt
        self.audience = audience
        self.relayProtocol = relayProtocol
        self.relays = relays
    }
}
