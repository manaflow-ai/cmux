/// The authorization already established before application bytes are sent.
public enum CmxTransportAuthorizationMode: Equatable, Sendable {
    /// RPC requests must add a Stack bearer on an approved transport.
    case stackBearer
    /// An older pairing may send a Stack bearer only to the exact Tailscale
    /// peer captured by this persisted compatibility grant.
    case legacyTailscaleBearer(CmxLegacyTailscaleAuthorizationEvidence)
    /// A user-entered compatibility code may send a Stack bearer only to the
    /// exact Tailscale peer address it named. The device identity a code may
    /// claim is self-reported and adds no authority; the entry of the code in
    /// the pairing UI is the authorization event, and the value never outlives
    /// that pairing dial.
    case userAuthorizedTailscalePairing(CmxUserTailscalePairingAuthorization)
}

/// Route plus peer intent required to build a transport without substitution.
public struct CmxByteTransportRequest: Equatable, Sendable {
    /// The route the transport must dial without substituting another peer.
    public let route: CmxAttachRoute
    /// The authenticated peer device expected on the route, when known.
    public let expectedPeerDeviceID: String?
    /// The authorization evidence permitted on the transport.
    public let authorizationMode: CmxTransportAuthorizationMode
    /// The local owner whose network path this request represents.
    public let sessionPurpose: CmxTransportSessionPurpose

    /// Creates a route-bound transport request with explicit peer authority.
    public init(
        route: CmxAttachRoute,
        expectedPeerDeviceID: String?,
        authorizationMode: CmxTransportAuthorizationMode,
        sessionPurpose: CmxTransportSessionPurpose = .foregroundControl
    ) {
        self.route = route
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.authorizationMode = authorizationMode
        self.sessionPurpose = sessionPurpose
    }

    /// Returns the same route and authority with a different local owner role.
    public func withSessionPurpose(
        _ sessionPurpose: CmxTransportSessionPurpose
    ) -> Self {
        Self(
            route: route,
            expectedPeerDeviceID: expectedPeerDeviceID,
            authorizationMode: authorizationMode,
            sessionPurpose: sessionPurpose
        )
    }
}
