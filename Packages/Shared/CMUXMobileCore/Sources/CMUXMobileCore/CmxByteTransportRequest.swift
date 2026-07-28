/// The authorization already established before application bytes are sent.
public enum CmxTransportAuthorizationMode: Equatable, Sendable {
    /// RPC requests must add a Stack bearer on an approved transport.
    case stackBearer
    /// A pairing established before Iroh may send a Stack bearer only to the
    /// exact Tailscale peer captured by this persisted compatibility grant.
    case legacyTailscaleBearer(CmxLegacyTailscaleAuthorizationEvidence)
    /// The transport handshake admitted this exact peer and account binding.
    case transportAdmission
}

/// Route plus peer intent required to build a transport without substitution.
public struct CmxByteTransportRequest: Equatable, Sendable {
    public let route: CmxAttachRoute
    public let expectedPeerDeviceID: String?
    public let authorizationMode: CmxTransportAuthorizationMode
    /// The local owner whose network path this request represents.
    public let sessionPurpose: CmxTransportSessionPurpose

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
}
