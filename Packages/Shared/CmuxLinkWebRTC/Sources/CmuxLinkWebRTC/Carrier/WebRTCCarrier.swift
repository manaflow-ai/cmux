public import CmuxLink
public import CmuxLinkSignaling
import Foundation
import os

/// The V1 dialer (a3-link.md section 8): signals an offer to the host over
/// the control plane, connects with ICE (P2P, else Cloudflare TURN), proves
/// both identities over the DTLS fingerprints, and returns a transport whose
/// lanes are data channels.
public final class WebRTCCarrier: LinkCarrier {
    public var kind: CarrierKind { .webrtc }
    public var candidatePaths: [PathKind] { [.p2p, .turn] }

    private let router: SignalRouter
    private let iceCache: ICEConfigurationCache
    private let identity: any WebRTCIdentity
    private let hostKeys: any WebRTCHostKeyResolver
    private let configuration: WebRTCConfiguration
    private let injector: WebRTCFaultInjector?
    // carve-out: the live set is updated from a synchronous finish callback.
    private let live = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: WebRTCConnection]())

    public convenience init(
        signaling: any SignalingChannel,
        iceServers: any ICEServerProvider,
        identity: any WebRTCIdentity,
        hostKeys: any WebRTCHostKeyResolver = WebRTCHintsResolver(),
        configuration: WebRTCConfiguration = WebRTCConfiguration()
    ) {
        self.init(router: SignalRouter(channel: signaling), iceServers: iceServers, identity: identity,
                  hostKeys: hostKeys, configuration: configuration, injector: nil)
    }

    /// Shares a router when one install both dials and accepts on one channel.
    public convenience init(
        router: SignalRouter,
        iceServers: any ICEServerProvider,
        identity: any WebRTCIdentity,
        hostKeys: any WebRTCHostKeyResolver = WebRTCHintsResolver(),
        configuration: WebRTCConfiguration = WebRTCConfiguration()
    ) {
        self.init(router: router, iceServers: iceServers, identity: identity,
                  hostKeys: hostKeys, configuration: configuration, injector: nil)
    }

    @_spi(Testing)
    public init(
        router: SignalRouter,
        iceServers: any ICEServerProvider,
        identity: any WebRTCIdentity,
        hostKeys: any WebRTCHostKeyResolver,
        configuration: WebRTCConfiguration,
        injector: WebRTCFaultInjector?
    ) {
        self.router = router
        iceCache = ICEConfigurationCache(provider: iceServers)
        self.identity = identity
        self.hostKeys = hostKeys
        self.configuration = configuration
        self.injector = injector
    }

    public func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        guard let hostKey = await hostKeys.hostKey(for: peer) else { throw WebRTCCarrierError.noHostKey }
        let ice = try await iceCache.configuration(for: peer.hostID)
        try Task.checkCancellation()
        let session = SignalSessionID().rawValue
        let inbox = await router.register(session)
        let webrtcPeer: WebRTCPeer
        do {
            webrtcPeer = try WebRTCPeer(
                factory: WebRTCFactory.shared(for: configuration.network), ice: ice,
                limits: PeerSendLimits(configuration)
            )
        } catch {
            await router.unregister(session)
            throw WebRTCCarrierError.connectFailed("peer connection: \(error)")
        }
        let context = WebRTCConnectionContext(
            session: session, hostID: peer.hostID, identity: identity, signaling: router.channel,
            router: router, iceCache: iceCache, configuration: configuration, injector: injector
        )
        let live = live
        let connection = WebRTCConnection(
            role: .dialer(hostKey: hostKey), context: context, peer: webrtcPeer,
            remoteTarget: peer.hints[WebRTCHintsResolver.signalTargetHint] ?? peer.hostID,
            onFinish: { connection in _ = live.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) } }
        )
        live.withLock { $0[ObjectIdentifier(connection)] = connection }
        await connection.attach(inbox: inbox)
        try await connection.dial()
        return WebRTCTransport(events: webrtcPeer.inbox.events, connection: connection, remoteKey: hostKey, install: nil)
    }

    /// The app's NWPathMonitor reported a change: restart ICE on every live
    /// transport at once (b2-webrtc.md section 7). Call next to
    /// `LinkSession.networkDidChange()`.
    public func networkDidChange() async {
        let connections = live.withLock { Array($0.values) }
        for connection in connections { await connection.restartICE() }
    }
}
