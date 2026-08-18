public import CMUXMobileCore

/// One broker mint: the endpoint-bound relay credentials and, when the
/// broker bundled it, the current signed relay policy.
public struct PeerRelayTokenGrant: Equatable, Sendable {
    /// Endpoint-bound relay credentials (300-second TTL JWTs today).
    public let credential: PeerRelayTokenResponse

    /// The compact-JWS signed relay policy from the same response, when the
    /// broker returned one (bootstrap responses do; pure refresh mints may not).
    public let signedPolicy: String?

    /// Creates one relay token grant.
    public init(
        credential: PeerRelayTokenResponse,
        signedPolicy: String? = nil
    ) {
        self.credential = credential
        self.signedPolicy = signedPolicy
    }
}

/// Narrow trust-broker boundary used by relay credential rotation.
///
/// The broker client conforms; relay code never sees HTTP, auth headers, or
/// retry policy. The credential is bound to the minting endpoint identity,
/// so the caller passes the exact endpoint the tokens will be applied to.
public protocol PeerRelayTokenServing: Sendable {
    /// Mints a fresh endpoint-bound credential set for the managed relay fleet.
    ///
    /// - Parameter endpointID: The endpoint identity the tokens are bound to.
    /// - Returns: The minted credentials plus any bundled signed policy.
    func mintRelayCredential(
        endpointID: CmxIrohPeerIdentity
    ) async throws -> PeerRelayTokenGrant
}
