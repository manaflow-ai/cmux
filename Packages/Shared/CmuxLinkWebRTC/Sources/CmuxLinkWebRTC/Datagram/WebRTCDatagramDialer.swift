public import CmuxLink
public import CmuxLinkSignaling
import Foundation

/// Opens datagram channels to a host: signals a `webrtc-wg` offer, runs ICE
/// with the minted TURN servers, and returns once `wg` is open.
public final class WebRTCDatagramDialer: Sendable {
    private let router: SignalRouter
    private let iceCache: ICEConfigurationCache
    private let configuration: WebRTCConfiguration
    private let injector: WebRTCFaultInjector?

    public convenience init(router: SignalRouter, iceServers: any ICEServerProvider, configuration: WebRTCConfiguration = WebRTCConfiguration()) {
        self.init(router: router, iceServers: iceServers, configuration: configuration, injector: nil)
    }

    @_spi(Testing)
    public init(router: SignalRouter, iceServers: any ICEServerProvider, configuration: WebRTCConfiguration, injector: WebRTCFaultInjector?) {
        self.router = router
        iceCache = ICEConfigurationCache(provider: iceServers)
        self.configuration = configuration
        self.injector = injector
    }

    public func open(to peer: LinkPeer) async throws -> WebRTCDatagramChannel {
        let ice = try await iceCache.configuration(for: peer.hostID)
        try Task.checkCancellation()
        let session = SignalSessionID().rawValue
        let inbox = await router.register(session)
        let (events, sink) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        let webrtcPeer: WebRTCPeer
        do {
            webrtcPeer = try WebRTCPeer(
                factory: WebRTCFactory.shared(for: configuration.network), mode: .datagram, ice: ice,
                lowWater: configuration.lowWaterBytes, frameSink: sink
            )
        } catch {
            await router.unregister(session)
            throw WebRTCCarrierError.connectFailed("peer connection: \(error)")
        }
        let context = WebRTCConnectionContext(
            session: session, hostID: peer.hostID, identity: nil, signaling: router.channel,
            router: router, iceCache: iceCache, configuration: configuration, injector: injector
        )
        let connection = WebRTCConnection(
            role: .dialer(hostKey: nil), context: context, peer: webrtcPeer,
            remoteTarget: peer.hints[WebRTCHintsResolver.signalTargetHint] ?? peer.hostID,
            onFinish: { _ in }
        )
        await connection.attach(inbox: inbox)
        try await connection.dial()
        return WebRTCDatagramChannel(raw: events, connection: connection)
    }
}
