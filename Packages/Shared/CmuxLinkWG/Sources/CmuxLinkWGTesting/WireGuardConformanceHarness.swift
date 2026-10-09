public import CmuxLink
public import CmuxLinkTesting
public import CmuxLinkWG

/// `LinkConformanceSuite` over the V2 carrier: real WireGuard handshake and
/// encryption and the lane protocol, on the in-memory underlay (seeded loss,
/// duplication, reorder and jitter) or on any other underlay, such as B2's
/// real WebRTC `wg` data channel.
/// `dropTransports` resets the underlays (the peer is gone, so the session
/// reconnects); `roam` kills them with `.pathLost`, which the transport
/// survives by opening a new underlay under the same WireGuard session.
public final class WireGuardConformanceHarness: ConformanceHarness {
    public let name: String
    private let configuration: WireGuardLinkConfiguration
    private let makeUnderlays: @Sendable () async throws -> UnderlayEndpoints
    private let box = EndpointsBox()

    /// The in-memory underlay network.
    public convenience init(
        name: String = "webrtc-wg-in-memory",
        conditions: UnderlayConditions = .perfect,
        configuration: WireGuardLinkConfiguration = WireGuardLinkConfiguration()
    ) {
        self.init(name: name, configuration: configuration) {
            let network = InMemoryUnderlayNetwork(conditions: conditions)
            return UnderlayEndpoints(dialer: network, listener: network, faults: network)
        }
    }

    /// Any underlay: `makeUnderlays` returns fresh endpoints for each case.
    public init(
        name: String,
        configuration: WireGuardLinkConfiguration = WireGuardLinkConfiguration(),
        makeUnderlays: @escaping @Sendable () async throws -> UnderlayEndpoints
    ) {
        self.name = name
        self.configuration = configuration
        self.makeUnderlays = makeUnderlays
    }

    public func makeEndpoints() async throws -> ConformanceEndpoints {
        let underlays = try await makeUnderlays()
        let hostKey = WireGuardPrivateKey()
        let deviceKey = WireGuardPrivateKey()
        let hostID = "conformance-host"
        let acceptor = WireGuardOverWebRTCAcceptor(
            identity: hostKey,
            hostID: hostID,
            underlays: underlays.listener,
            authorizer: WireGuardPinnedAuthorizer(peers: [deviceKey.publicKey: "conformance-device"]),
            configuration: configuration
        )
        await acceptor.start()
        let carrier = WireGuardOverWebRTCCarrier(
            identity: deviceKey,
            installID: "conformance-device",
            underlays: underlays.dialer,
            configuration: configuration
        )
        await box.set(underlays, acceptor)
        return ConformanceEndpoints(
            carriers: [carrier],
            acceptor: acceptor,
            peer: LinkPeer(hostID: hostID, hints: WireGuardHintsResolver().hints(for: hostKey.publicKey))
        )
    }

    public func dropTransports() async -> Bool {
        guard let faults = await box.underlays?.faults else { return false }
        await faults.reset()
        return true
    }

    public func changePath(to kind: PathKind) async -> Bool {
        guard let faults = await box.underlays?.faults else { return false }
        await faults.changePath(to: kind)
        return true
    }

    public func roam(to kind: PathKind) async -> Bool {
        guard let faults = await box.underlays?.faults else { return false }
        await faults.roam(to: kind)
        return true
    }

    public func throttle(bytesPerSecond: Int?) async -> Bool {
        guard let faults = await box.underlays?.faults else { return false }
        return await faults.throttle(bytesPerSecond: bytesPerSecond)
    }

    public func tearDown() async {
        await box.acceptor?.stop()
        await box.underlays?.stop()
        await box.set(nil, nil)
    }

    private actor EndpointsBox {
        private(set) var underlays: UnderlayEndpoints?
        private(set) var acceptor: WireGuardOverWebRTCAcceptor?

        func set(_ underlays: UnderlayEndpoints?, _ acceptor: WireGuardOverWebRTCAcceptor?) {
            self.underlays = underlays
            self.acceptor = acceptor
        }
    }
}
