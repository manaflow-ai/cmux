import CmuxLink
import CmuxLinkSignaling
import CmuxLinkTesting
@_spi(Testing) import CmuxLinkWebRTC

/// V1: two in-process libwebrtc peers on loopback host candidates (real ICE,
/// DTLS, SCTP data channels), signaled through the in-memory relay. Drop and
/// roam go through `WebRTCFaultInjector`; no packet loss or delay can be
/// injected under libwebrtc's own sockets (use the dnctl recipe).
final class WebRTCBenchRig: ConformanceHarness {
    let name = "v1-webrtc-loopback"
    private let state = RigState<WebRTCFaultInjector, WebRTCAcceptor>()

    static let hostID = "h_bench01"
    static let phoneInstall = "in_bench01"
    static let configuration = WebRTCConfiguration(
        connectTimeout: .seconds(10),
        iceRestartTimeout: .seconds(5),
        disconnectedGrace: .milliseconds(500),
        closeTimeout: .seconds(2),
        network: .loopbackOnly
    )

    func makeEndpoints() async throws -> ConformanceEndpoints {
        let hub = InMemorySignalingHub()
        let injector = WebRTCFaultInjector()
        let hostIdentity = SoftwareWebRTCIdentity()
        let deviceIdentity = SoftwareWebRTCIdentity()
        let acceptor = WebRTCAcceptor(
            router: SignalRouter(channel: hub.endpoint(id: Self.hostID)),
            iceServers: StaticICEServerProvider(.hostOnly),
            identity: hostIdentity,
            hostID: Self.hostID,
            authorizer: WebRTCPinnedAuthorizer(devices: [deviceIdentity.publicKey]),
            configuration: Self.configuration,
            injector: injector
        )
        await acceptor.start()
        let carrier = WebRTCCarrier(
            router: SignalRouter(channel: hub.endpoint(id: Self.phoneInstall)),
            iceServers: StaticICEServerProvider(.hostOnly),
            identity: deviceIdentity,
            hostKeys: WebRTCHintsResolver(),
            configuration: Self.configuration,
            injector: injector
        )
        await state.set(injector, acceptor)
        return ConformanceEndpoints(
            carriers: [carrier],
            acceptor: acceptor,
            peer: LinkPeer(hostID: Self.hostID, hints: WebRTCHintsResolver().hints(hostKey: hostIdentity.publicKey))
        )
    }

    func dropTransports() async -> Bool {
        guard let injector = await state.faults else { return false }
        await injector.dropAll()
        return true
    }

    func changePath(to kind: PathKind) async -> Bool {
        guard let injector = await state.faults else { return false }
        await injector.changePath(to: kind)
        return true
    }

    func roam(to kind: PathKind) async -> Bool {
        guard let injector = await state.faults else { return false }
        await injector.roam(to: kind)
        return true
    }

    func tearDown() async {
        await state.owner?.stop()
        await state.set(nil, nil)
    }
}
