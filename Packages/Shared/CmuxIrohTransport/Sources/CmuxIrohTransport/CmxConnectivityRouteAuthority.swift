/// Connection-authority fields whose change requires retiring an admitted peer.
///
/// Reachability hints, direct ports, display names, and last-seen timestamps are
/// deliberately excluded because Iroh migrates paths on the existing QUIC session.
struct CmxConnectivityRouteAuthority: Equatable, Sendable {
    let bindingID: String
    let appInstanceID: String
    let tag: String
    let platform: CmxIrohPlatform
    let identityGeneration: Int
    let pairingEnabled: Bool
    let capabilities: [String]

    init(binding: CmxIrohBrokerBinding) {
        bindingID = binding.bindingID
        appInstanceID = binding.appInstanceID
        tag = binding.tag
        platform = binding.platform
        identityGeneration = binding.identityGeneration
        pairingEnabled = binding.pairingEnabled
        capabilities = binding.capabilities.sorted()
    }
}

struct CmxConnectivityRouteAuthorityIndex: Sendable {
    let revision: UInt64?
    let authorities: [
        CmxConnectivityPeerID: CmxConnectivityRouteAuthority
    ]

    init(discovery: CmxIrohDiscoveryResponse) throws {
        revision = discovery.revision
        var indexed: [
            CmxConnectivityPeerID: CmxConnectivityRouteAuthority
        ] = [:]
        for binding in discovery.bindings {
            let peerID = CmxConnectivityPeerID(
                identity: binding.endpointID,
                deviceID: binding.deviceID
            )
            guard indexed[peerID] == nil else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            indexed[peerID] = CmxConnectivityRouteAuthority(binding: binding)
        }
        authorities = indexed
    }

    /// Returns only active peers revoked, substituted, or authority-mutated by
    /// this complete replacement snapshot.
    func invalidatedPeers(
        replacing previous: Self?,
        activePeers: Set<CmxConnectivityPeerID>
    ) -> Set<CmxConnectivityPeerID> {
        Set(activePeers.filter { peerID in
            guard let replacement = authorities[peerID] else { return true }
            guard let previousAuthority = previous?.authorities[peerID] else {
                return false
            }
            return previousAuthority != replacement
        })
    }
}
