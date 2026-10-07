import CmuxLink
@_spi(Testing) import CmuxLinkWebRTC
import Foundation

/// A dialer carrier and host acceptor over an in-memory relay and loopback
/// ICE (host candidates only, no STUN or TURN).
struct WebRTCPair: Sendable {
    static let hostID = "h_mac1A2b"
    static let phoneInstall = "in_phone01"

    let hub: InMemorySignalingHub
    let injector: WebRTCFaultInjector
    let hostIdentity: SoftwareWebRTCIdentity
    let deviceIdentity: SoftwareWebRTCIdentity
    let carrier: WebRTCCarrier
    let acceptor: WebRTCAcceptor
    let peer: LinkPeer

    static let configuration = WebRTCConfiguration(
        connectTimeout: .seconds(10),
        iceRestartTimeout: .seconds(5),
        disconnectedGrace: .milliseconds(500),
        closeTimeout: .seconds(2),
        network: .loopbackOnly
    )

    init(
        hostIdentity: SoftwareWebRTCIdentity = SoftwareWebRTCIdentity(),
        deviceIdentity: SoftwareWebRTCIdentity = SoftwareWebRTCIdentity(),
        pinnedHostKey: WebRTCPublicKey? = nil,
        authorizedDevices: Set<WebRTCPublicKey>? = nil,
        configuration: WebRTCConfiguration = Self.configuration
    ) async {
        let hub = InMemorySignalingHub()
        let injector = WebRTCFaultInjector()
        let acceptor = WebRTCAcceptor(
            router: SignalRouter(channel: hub.endpoint(id: Self.hostID)),
            iceServers: StaticICEServerProvider(.hostOnly),
            identity: hostIdentity,
            hostID: Self.hostID,
            authorizer: WebRTCPinnedAuthorizer(devices: authorizedDevices ?? [deviceIdentity.publicKey]),
            configuration: configuration,
            injector: injector
        )
        await acceptor.start()
        let carrier = WebRTCCarrier(
            router: SignalRouter(channel: hub.endpoint(id: Self.phoneInstall)),
            iceServers: StaticICEServerProvider(.hostOnly),
            identity: deviceIdentity,
            hostKeys: WebRTCHintsResolver(),
            configuration: configuration,
            injector: injector
        )
        self.hub = hub
        self.injector = injector
        self.hostIdentity = hostIdentity
        self.deviceIdentity = deviceIdentity
        self.carrier = carrier
        self.acceptor = acceptor
        peer = LinkPeer(
            hostID: Self.hostID,
            hints: WebRTCHintsResolver().hints(hostKey: pinnedHostKey ?? hostIdentity.publicKey)
        )
    }

    /// Connects once and returns both ends.
    func connect() async throws -> (WebRTCTransport, WebRTCTransport) {
        let incoming = acceptor.incoming
        async let accepted: (any LinkTransport)? = {
            for await transport in incoming { return transport }
            return nil
        }()
        let dialed = try await carrier.connect(to: peer)
        guard let hostSide = await accepted as? WebRTCTransport, let dialer = dialed as? WebRTCTransport else {
            throw WebRTCTestError.noTransport
        }
        return (dialer, hostSide)
    }

    func stop() async {
        await acceptor.stop()
    }
}

enum WebRTCTestError: Error {
    case noTransport
    case timeout
}
