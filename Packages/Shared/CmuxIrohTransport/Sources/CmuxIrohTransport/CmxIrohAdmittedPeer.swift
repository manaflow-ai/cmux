public import CMUXMobileCore

/// The device admitted after TLS and authenticated account-list or grant verification.
public struct CmxIrohAdmittedPeer: Equatable, Sendable {
    public let bindingID: String
    public let deviceID: String
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    /// Present only when the verifier authenticated a platform-bearing grant.
    /// Account-list admission is role-neutral; nil must never imply an iOS peer.
    public let platform: CmxIrohPlatform?

    init(
        bindingID: String,
        deviceID: String,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        platform: CmxIrohPlatform?
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.platform = platform
    }

    /// Copies a peer tuple that a verifier has already authenticated.
    /// Construction alone does not grant access; server admission also binds
    /// this tuple to the live QUIC TLS identity before exposing it to the host.
    public init(peer: CmxIrohGrantPeer) {
        self.init(
            bindingID: peer.bindingID,
            deviceID: peer.deviceID,
            endpointID: peer.endpointID,
            identityGeneration: peer.identityGeneration,
            platform: peer.platform
        )
    }

    /// Copies an account-list tuple already verified against the live TLS key.
    /// The device list grants account membership, without asserting a platform role.
    /// Construction alone does not authorize a connection.
    ///
    /// - Parameters:
    ///   - accountDeviceBindingID: The binding identified by the authenticated list.
    ///   - deviceID: The admitted physical device identifier.
    ///   - endpointID: The live TLS-authenticated endpoint identity.
    ///   - identityGeneration: The generation carried by the list.
    public init(
        accountDeviceBindingID: String,
        deviceID: String,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int
    ) {
        self.init(
            bindingID: accountDeviceBindingID, deviceID: deviceID,
            endpointID: endpointID, identityGeneration: identityGeneration,
            platform: nil
        )
    }

    init(attestation: CmxIrohEndpointAttestationClaims) {
        self.init(
            bindingID: attestation.bindingID,
            deviceID: attestation.deviceID,
            endpointID: attestation.endpointID,
            identityGeneration: attestation.identityGeneration,
            platform: attestation.platform
        )
    }
}
