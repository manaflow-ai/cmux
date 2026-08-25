/// The authorization already established before application bytes are sent.
public enum CmxTransportAuthorizationMode: Equatable, Sendable {
    /// RPC requests must add a Stack bearer on an approved transport.
    case stackBearer
    /// A pairing established before Iroh may send a Stack bearer only to the
    /// exact Tailscale peer captured by this persisted compatibility grant.
    case legacyTailscaleBearer(CmxLegacyTailscaleAuthorizationEvidence)
    /// A user-entered compatibility code may send a Stack bearer only to the
    /// exact Tailscale peer address it named. The device identity a code may
    /// claim is self-reported and adds no authority; the entry of the code in
    /// the pairing UI is the authorization event, and the value never outlives
    /// that pairing dial.
    case userAuthorizedTailscalePairing(CmxUserTailscalePairingAuthorization)
    /// The transport handshake admitted this exact peer and account binding.
    case transportAdmission
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
    /// When non-nil, the Iroh dial for this request may attempt ONLY these
    /// user-pinned addresses (the per-Computer "Direct" connection method):
    /// no relay path, no broker-advertised or discovered paths, and no LAN or
    /// custom private-path joins. An empty or unusable allowlist must fail
    /// the dial instead of substituting another path.
    public let irohDirectOnlyDialCandidates: [CmxIrohDirectDialCandidate]?
    /// The hard transport-class policy captured for this physical dial.
    public let transportMode: CmxTransportMode

    /// Creates a route-bound transport request with explicit peer authority.
    public init(
        route: CmxAttachRoute,
        expectedPeerDeviceID: String?,
        authorizationMode: CmxTransportAuthorizationMode,
        sessionPurpose: CmxTransportSessionPurpose = .foregroundControl,
        irohDirectOnlyDialCandidates: [CmxIrohDirectDialCandidate]? = nil,
        transportMode: CmxTransportMode = .automatic
    ) {
        self.route = route
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.authorizationMode = authorizationMode
        self.sessionPurpose = sessionPurpose
        self.irohDirectOnlyDialCandidates = irohDirectOnlyDialCandidates
        self.transportMode = transportMode
    }

    /// Returns the same route and authority with a different local owner role.
    public func withSessionPurpose(
        _ sessionPurpose: CmxTransportSessionPurpose
    ) -> Self {
        Self(
            route: route,
            expectedPeerDeviceID: expectedPeerDeviceID,
            authorizationMode: authorizationMode,
            sessionPurpose: sessionPurpose,
            irohDirectOnlyDialCandidates: irohDirectOnlyDialCandidates,
            transportMode: transportMode
        )
    }

    /// Enforces the selected mode at the last common boundary before a
    /// transport factory can allocate a socket or Iroh session.
    public func validateTransportMode() throws {
        try CmxTransportModePolicy(transportMode).validate(route: route)
        if transportMode == .direct,
           irohDirectOnlyDialCandidates?.isEmpty != false {
            throw CmxTransportModeError.noRoute(
                mode: .direct,
                macDisplayName: nil
            )
        }
    }
}
