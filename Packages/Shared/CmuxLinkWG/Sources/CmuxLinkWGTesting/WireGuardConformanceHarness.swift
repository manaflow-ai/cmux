public import CmuxLink
public import CmuxLinkTesting
public import CmuxLinkWG

/// `LinkConformanceSuite` over the V2 carrier on the in-memory underlay:
/// real WireGuard handshake and encryption, the lane protocol, and seeded
/// loss, duplication, reorder and jitter on every datagram.
/// `dropTransports` resets the underlays (the peer is gone, so the session
/// reconnects); `roam` kills them with `.pathLost`, which the transport
/// survives by opening a new underlay under the same WireGuard session.
public final class WireGuardConformanceHarness: ConformanceHarness {
    public let name: String
    private let conditions: UnderlayConditions
    private let configuration: WireGuardLinkConfiguration
    private let box = NetworkBox()

    public init(
        name: String = "webrtc-wg-in-memory",
        conditions: UnderlayConditions = .perfect,
        configuration: WireGuardLinkConfiguration = WireGuardLinkConfiguration()
    ) {
        self.name = name
        self.conditions = conditions
        self.configuration = configuration
    }

    public func makeEndpoints() async throws -> ConformanceEndpoints {
        let network = InMemoryUnderlayNetwork(conditions: conditions)
        let hostKey = WireGuardPrivateKey()
        let deviceKey = WireGuardPrivateKey()
        let hostID = "conformance-host"
        let acceptor = WireGuardOverWebRTCAcceptor(
            identity: hostKey,
            hostID: hostID,
            underlays: network,
            authorizer: WireGuardPinnedAuthorizer(peers: [deviceKey.publicKey: "conformance-device"]),
            configuration: configuration
        )
        await acceptor.start()
        let carrier = WireGuardOverWebRTCCarrier(
            identity: deviceKey,
            installID: "conformance-device",
            underlays: network,
            configuration: configuration
        )
        await box.set(network, acceptor)
        return ConformanceEndpoints(
            carriers: [carrier],
            acceptor: acceptor,
            peer: LinkPeer(hostID: hostID, hints: WireGuardHintsResolver().hints(for: hostKey.publicKey))
        )
    }

    public func dropTransports() async -> Bool {
        guard let network = await box.network else { return false }
        await network.reset()
        return true
    }

    public func changePath(to kind: PathKind) async -> Bool {
        guard let network = await box.network else { return false }
        await network.changePath(to: kind)
        return true
    }

    public func roam(to kind: PathKind) async -> Bool {
        guard let network = await box.network else { return false }
        await network.roam(to: kind)
        return true
    }

    public func throttle(bytesPerSecond: Int?) async -> Bool {
        guard let network = await box.network else { return false }
        var next = await network.conditions
        next.bytesPerSecond = bytesPerSecond
        await network.setConditions(next)
        return true
    }

    public func tearDown() async {
        await box.acceptor?.stop()
        await box.set(nil, nil)
    }

    private actor NetworkBox {
        private(set) var network: InMemoryUnderlayNetwork?
        private(set) var acceptor: WireGuardOverWebRTCAcceptor?

        func set(_ network: InMemoryUnderlayNetwork?, _ acceptor: WireGuardOverWebRTCAcceptor?) {
            self.network = network
            self.acceptor = acceptor
        }
    }
}
