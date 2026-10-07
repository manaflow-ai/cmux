public import CmuxLinkSignaling
import CmuxLink
import Foundation
import os

/// The host side of datagram channels: answers `webrtc-wg` offers and
/// yields each channel once `wg` is open.
public final class WebRTCDatagramListener: Sendable {
    /// Open channels queued for a consumer that has not taken them yet; one
    /// past this is closed (the dialer retries).
    public static let pendingChannelLimit = 64

    public let incoming: AsyncStream<WebRTCDatagramChannel>
    private let incomingSink: AsyncStream<WebRTCDatagramChannel>.Continuation
    private let router: SignalRouter
    private let iceCache: ICEConfigurationCache
    private let hostID: String
    private let configuration: WebRTCConfiguration
    private let injector: WebRTCFaultInjector?
    // carve-out: idempotent start/stop guard, never held across an await.
    private let runner = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public convenience init(router: SignalRouter, iceServers: any ICEServerProvider, hostID: String,
                            configuration: WebRTCConfiguration = WebRTCConfiguration()) {
        self.init(router: router, iceServers: iceServers, hostID: hostID, configuration: configuration, injector: nil)
    }

    @_spi(Testing)
    public init(router: SignalRouter, iceServers: any ICEServerProvider, hostID: String,
                configuration: WebRTCConfiguration, injector: WebRTCFaultInjector?) {
        (incoming, incomingSink) = AsyncStream.makeStream(of: WebRTCDatagramChannel.self, bufferingPolicy: .bufferingOldest(Self.pendingChannelLimit))
        self.router = router
        iceCache = ICEConfigurationCache(provider: iceServers)
        self.hostID = hostID
        self.configuration = configuration
        self.injector = injector
    }

    public func start() async {
        guard runner.withLock({ $0 == nil }) else { return }
        let sessions = await router.newSessions(for: .webrtcWireGuard)
        let task = Task { [weak self] in
            for await incoming in sessions {
                guard let self else { return }
                Task { await self.accept(incoming) }
            }
        }
        runner.withLock { $0 = task }
    }

    public func stop() {
        runner.withLock { task in
            task?.cancel()
            task = nil
        }
        incomingSink.finish()
    }

    private func accept(_ incoming: SignalRouter.Incoming) async {
        let ice = (try? await iceCache.configuration(for: hostID)) ?? .stunOnly
        guard let peer = try? WebRTCPeer(
            factory: WebRTCFactory.shared(for: configuration.network, host: true), mode: .datagram, ice: ice,
            limits: PeerSendLimits(configuration)
        ) else {
            await router.unregister(incoming.session)
            return
        }
        let context = WebRTCConnectionContext(
            session: incoming.session, hostID: hostID, identity: nil, signaling: router.channel,
            router: router, iceCache: iceCache, configuration: configuration, injector: injector
        )
        let connection = WebRTCConnection(role: .host(authorizer: nil), context: context, peer: peer, remoteTarget: "", onFinish: { _ in })
        await connection.startHost(inbox: incoming.inbox)
        do {
            try await connection.accept()
        } catch {
            return
        }
        let channel = WebRTCDatagramChannel(inbox: peer.inbox, connection: connection)
        switch incomingSink.yield(channel) {
        case .enqueued: break
        case .dropped, .terminated: await channel.close()
        @unknown default: await channel.close()
        }
    }
}
