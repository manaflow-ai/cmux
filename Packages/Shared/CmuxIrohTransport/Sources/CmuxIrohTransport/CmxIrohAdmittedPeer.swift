public import CMUXMobileCore

/// The exact iOS binding admitted by the Mac after TLS and grant verification.
public struct CmxIrohAdmittedPeer: Equatable, Sendable {
    public let bindingID: String
    public let deviceID: String
    public let endpointID: CmxIrohPeerIdentity
    public let identityGeneration: Int
    public let platform: CmxIrohPlatform

    init(
        bindingID: String,
        deviceID: String,
        endpointID: CmxIrohPeerIdentity,
        identityGeneration: Int,
        platform: CmxIrohPlatform
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.platform = platform
    }

    init(peer: CmxIrohGrantPeer) {
        self.init(
            bindingID: peer.bindingID,
            deviceID: peer.deviceID,
            endpointID: peer.endpointID,
            identityGeneration: peer.identityGeneration,
            platform: peer.platform
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
