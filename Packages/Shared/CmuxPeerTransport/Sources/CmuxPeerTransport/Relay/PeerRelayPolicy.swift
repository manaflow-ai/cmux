/// A verified, bounded catalog of managed relays.
///
/// Instances are only produced by ``PeerRelayPolicyVerifier`` after the
/// Ed25519 signature and the strict claim shape both check out, so holding a
/// value is proof of verification.
public struct PeerRelayPolicy: Equatable, Sendable {
    /// Policy schema version.
    public let version: Int

    /// Canonical lowercase UUID identifying this signed policy publication.
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

    /// Ordered managed relay catalog.
    public let relays: [PeerRelayDescriptor]

    init(
        version: Int,
        policyID: String,
        sequence: Int64,
        issuedAt: Int64,
        notBefore: Int64,
        expiresAt: Int64,
        audience: String,
        relayProtocol: String,
        relays: [PeerRelayDescriptor]
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

/// One broker-managed relay advertised by a verified signed policy.
///
/// Descriptors are credential-free: the signed policy names HTTPS origins
/// only, and endpoint-bound tokens are minted separately per endpoint.
public struct PeerRelayDescriptor: Equatable, Hashable, Sendable {
    /// Stable identifier used for diagnostics and selection.
    public let id: String

    /// Stable provider identifier such as `cmux` or `n0`.
    public let provider: String

    /// Provider-defined region identifier.
    public let region: String

    /// Canonical HTTPS relay origin.
    public let url: String

    init(id: String, provider: String, region: String, url: String) {
        self.id = id
        self.provider = provider
        self.region = region
        self.url = url
    }
}
