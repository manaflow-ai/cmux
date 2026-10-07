public import CmuxLink
public import CmuxLinkSignaling
import Foundation
import os

/// The V1 host side (a3-link.md section 8): answers offers relayed to this
/// Mac, refuses devices its trust store does not know, and yields each
/// transport once its control channel is open. B5 passes it to `MobileHost`.
public final class WebRTCAcceptor: LinkAcceptor {
    public let incoming: AsyncStream<any LinkTransport>
    private let incomingSink: AsyncStream<any LinkTransport>.Continuation
    private let router: SignalRouter
    private let iceCache: ICEConfigurationCache
    private let identity: any WebRTCIdentity
    private let hostID: String
    private let authorizer: any WebRTCAuthorizer
    private let configuration: WebRTCConfiguration
    private let injector: WebRTCFaultInjector?
    // carve-out: start/stop guard and the live set are touched from synchronous
    // finish callbacks; neither is held across an await.
    private let runner = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let live = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: WebRTCConnection]())

    public convenience init(
        signaling: any SignalingChannel,
        iceServers: any ICEServerProvider,
        identity: any WebRTCIdentity,
        hostID: String,
        authorizer: any WebRTCAuthorizer,
        configuration: WebRTCConfiguration = WebRTCConfiguration()
    ) {
        self.init(router: SignalRouter(channel: signaling), iceServers: iceServers, identity: identity,
                  hostID: hostID, authorizer: authorizer, configuration: configuration, injector: nil)
    }

    /// Shares the host socket's router with the V2 underlay listener (one
    /// `SignalFrameChannel` per host socket, offers routed by carrier).
    public convenience init(
        router: SignalRouter,
        iceServers: any ICEServerProvider,
        identity: any WebRTCIdentity,
        hostID: String,
        authorizer: any WebRTCAuthorizer,
        configuration: WebRTCConfiguration = WebRTCConfiguration()
    ) {
        self.init(router: router, iceServers: iceServers, identity: identity,
                  hostID: hostID, authorizer: authorizer, configuration: configuration, injector: nil)
    }

    @_spi(Testing)
    public init(
        router: SignalRouter,
        iceServers: any ICEServerProvider,
        identity: any WebRTCIdentity,
        hostID: String,
        authorizer: any WebRTCAuthorizer,
        configuration: WebRTCConfiguration,
        injector: WebRTCFaultInjector?
    ) {
        (incoming, incomingSink) = AsyncStream.makeStream(of: (any LinkTransport).self, bufferingPolicy: .unbounded)
        self.router = router
        iceCache = ICEConfigurationCache(provider: iceServers)
        self.identity = identity
        self.hostID = hostID
        self.authorizer = authorizer
        self.configuration = configuration
        self.injector = injector
    }

    /// Starts answering offers. Idempotent.
    public func start() async {
        let alreadyRunning = runner.withLock { $0 != nil }
        guard !alreadyRunning else { return }
        let sessions = await router.newSessions(for: .webrtc)
        let task = Task { [weak self] in
            for await incoming in sessions {
                guard let self else { return }
                Task { await self.accept(incoming) }
            }
        }
        runner.withLock { $0 = task }
    }

    /// Stops answering and closes every live transport.
    public func stop() async {
        runner.withLock { task in
            task?.cancel()
            task = nil
        }
        await router.stop()
        let connections = live.withLock { Array($0.values) }
        for connection in connections { await connection.close() }
        incomingSink.finish()
    }

    private func accept(_ incoming: SignalRouter.Incoming) async {
        let ice = (try? await iceCache.configuration(for: hostID)) ?? .stunOnly
        let (events, sink) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        guard let peer = try? WebRTCPeer(
            factory: WebRTCFactory.shared(for: configuration.network, host: true), ice: ice,
            limits: PeerSendLimits(configuration), frameSink: sink
        ) else {
            await router.unregister(incoming.session)
            return
        }
        let context = WebRTCConnectionContext(
            session: incoming.session, hostID: hostID, identity: identity, signaling: router.channel,
            router: router, iceCache: iceCache, configuration: configuration, injector: injector
        )
        let live = live
        let connection = WebRTCConnection(
            role: .host(authorizer: authorizer), context: context, peer: peer, remoteTarget: "",
            onFinish: { connection in _ = live.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) } }
        )
        live.withLock { $0[ObjectIdentifier(connection)] = connection }
        await connection.startHost(inbox: incoming.inbox)
        do {
            try await connection.accept()
        } catch {
            return
        }
        guard let key = await connection.remoteKey else { return }
        incomingSink.yield(WebRTCTransport(
            events: events, connection: connection, remoteKey: key, install: await connection.remoteInstall
        ))
    }
}
