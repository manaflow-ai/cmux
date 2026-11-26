/// Authoritative route material whose change requires live session teardown.
///
/// Volatile freshness fields are excluded on purpose: `last_seen_at`, path
/// hints, direct ports, and display names move on every registration
/// heartbeat and shape only the next dial, never the trust of an already
/// admitted connection. Comparing this content lets a route revision bump
/// keep healthy sessions whose routes did not materially change.
struct CmxConnectivityRouteContent: Equatable, Sendable {
    /// Trust material shared by every route in one account snapshot.
    ///
    /// Relay fleet and verification key order carries no trust meaning, so
    /// both are canonicalized here and a reorder-only revision compares
    /// equal to the installed material.
    struct AccountMaterial: Equatable, Sendable {
        let relayFleet: [String]
        let lanRendezvous: CmxIrohLANRendezvous
        let grantVerificationKeys: CmxIrohGrantVerificationKeySet

        init(snapshot: CmxIrohDiscoveryResponse) {
            relayFleet = snapshot.relayFleet.sorted()
            lanRendezvous = snapshot.lanRendezvous
            let keySet = snapshot.grantVerificationKeys
            grantVerificationKeys = CmxIrohGrantVerificationKeySet(
                version: keySet.version,
                currentKeyID: keySet.currentKeyID,
                keys: keySet.keys.sorted {
                    ($0.kid, $0.alg, $0.spkiDerBase64)
                        < ($1.kid, $1.alg, $1.spkiDerBase64)
                }
            )
        }
    }

    /// Admission-relevant material of one broker binding.
    struct BindingMaterial: Equatable, Sendable {
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
            // The admission policy reads capabilities with set semantics.
            capabilities = binding.capabilities.sorted()
        }
    }

    let account: AccountMaterial
    private let peerRoutes: [CmxConnectivityPeerID: [BindingMaterial]]

    init(snapshot: CmxIrohDiscoveryResponse) {
        account = AccountMaterial(snapshot: snapshot)
        var routes: [CmxConnectivityPeerID: [BindingMaterial]] = [:]
        for binding in snapshot.bindings {
            let peerID = CmxConnectivityPeerID(
                identity: binding.endpointID,
                deviceID: binding.deviceID
            )
            routes[peerID, default: []].append(BindingMaterial(binding: binding))
        }
        peerRoutes = routes.mapValues { bindings in
            bindings.sorted { $0.bindingID < $1.bindingID }
        }
    }

    /// Returns the material route for one peer, or nil when unrouted.
    func peerRoute(
        for peerID: CmxConnectivityPeerID
    ) -> [BindingMaterial]? {
        peerRoutes[peerID]
    }
}
