import CmuxLink
import CmuxLinkSignaling
import CmuxLinkWebRTC
import CmuxLinkWebRTCUnderlay
import CmuxLinkWG

/// The host-side inputs required to accept a split V1/V2 benchmark.
///
/// This is deliberately an explicit dependency rather than a default. A real
/// Mac supplies the router and ICE provider from its B1 HostDO socket; tests
/// may supply an ``InMemorySignalingHub`` endpoint and static ICE. Without
/// those inputs a host must refuse V1/V2 instead of opening a direct fallback.
public struct BenchAcceptingHost: Sendable {
    public let hostID: String
    public let router: SignalRouter
    public let iceServers: any ICEServerProvider
    public let webrtcIdentity: any WebRTCIdentity
    public let wireGuardIdentity: WireGuardPrivateKey
    public let allowedWebRTCDevices: Set<WebRTCPublicKey>
    public let allowedWireGuardDevices: Set<WireGuardPublicKey>
    public let webrtcConfiguration: WebRTCConfiguration
    public let wireGuardConfiguration: WireGuardLinkConfiguration

    public init(
        hostID: String,
        router: SignalRouter,
        iceServers: any ICEServerProvider,
        webrtcIdentity: any WebRTCIdentity,
        wireGuardIdentity: WireGuardPrivateKey,
        allowedWebRTCDevices: Set<WebRTCPublicKey>,
        allowedWireGuardDevices: Set<WireGuardPublicKey>,
        webrtcConfiguration: WebRTCConfiguration = .init(),
        wireGuardConfiguration: WireGuardLinkConfiguration = .init()
    ) throws {
        guard !hostID.isEmpty else { throw BenchSplitError.invalidDescriptor("host endpoint") }
        guard !allowedWebRTCDevices.isEmpty || !allowedWireGuardDevices.isEmpty else {
            throw BenchSplitError.unauthorized("accepting host has no paired device keys")
        }
        self.hostID = hostID
        self.router = router
        self.iceServers = iceServers
        self.webrtcIdentity = webrtcIdentity
        self.wireGuardIdentity = wireGuardIdentity
        self.allowedWebRTCDevices = allowedWebRTCDevices
        self.allowedWireGuardDevices = allowedWireGuardDevices
        self.webrtcConfiguration = webrtcConfiguration
        self.wireGuardConfiguration = wireGuardConfiguration
    }

    /// Creates the selected accepting carrier. V1 and V2 share the router,
    /// matching the production `MobileHostAssembly` and B1 socket contract.
    public func makeAcceptor(for rig: BenchRigKind) throws -> BenchAcceptingAcceptor {
        switch rig {
        case .v1:
            let acceptor = WebRTCAcceptor(
                router: router,
                iceServers: iceServers,
                identity: webrtcIdentity,
                hostID: hostID,
                authorizer: WebRTCPinnedAuthorizer(devices: allowedWebRTCDevices),
                configuration: webrtcConfiguration
            )
            return BenchAcceptingAcceptor(acceptors: [acceptor], start: { await acceptor.start() }, stop: { await acceptor.stop() })
        case .v2WebRTC:
            let listener = WebRTCDatagramListener(
                router: router,
                iceServers: iceServers,
                hostID: hostID,
                configuration: webrtcConfiguration
            )
            let acceptor = WireGuardOverWebRTCAcceptor(
                identity: wireGuardIdentity,
                hostID: hostID,
                underlays: WebRTCUnderlayListener(listener: listener),
                authorizer: PinnedWireGuardAuthorizer(devices: allowedWireGuardDevices),
                configuration: wireGuardConfiguration
            )
            return BenchAcceptingAcceptor(
                acceptors: [acceptor],
                start: {
                    await listener.start()
                    await acceptor.start()
                },
                stop: {
                    await acceptor.stop()
                    listener.stop()
                }
            )
        case .v2Memory, .v3, .reference:
            throw BenchSplitError.invalidDescriptor("accepting host does not implement rig (rig.rawValue)")
        }
    }

    public var webrtcHostKey: String { webrtcIdentity.publicKey.base64 }
    public var wireGuardHostKey: String { wireGuardIdentity.publicKey.base64 }
}

/// A lifecycle-aware fan-in for the one or more accepting carriers used by
/// ``BenchSplitServer`` or a host integration. `incoming` is consumed by one
/// `LinkHost`, exactly as in `MobileHostAssembly`.
public final class BenchAcceptingAcceptor: LinkAcceptor, @unchecked Sendable {
    public let incoming: AsyncStream<any LinkTransport>
    private let startImpl: @Sendable () async -> Void
    private let stopImpl: @Sendable () async -> Void
    private let task: Task<Void, Never>

    init(
        acceptors: [any LinkAcceptor],
        start: @escaping @Sendable () async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: (any LinkTransport).self,
            bufferingPolicy: .bufferingOldest(Self.pendingTransportLimit)
        )
        incoming = stream
        startImpl = start
        stopImpl = stop
        let sources = acceptors.map(\.incoming)
        let fanInTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask {
                        for await transport in source {
                            switch continuation.yield(transport) {
                            case .enqueued: break
                            case .dropped, .terminated: await transport.close()
                            @unknown default: await transport.close()
                            }
                        }
                    }
                }
            }
            continuation.finish()
        }
        task = fanInTask
        continuation.onTermination = { _ in fanInTask.cancel() }
    }

    public func start() async { await startImpl() }

    public func stop() async {
        await stopImpl()
        task.cancel()
    }
}

private struct PinnedWireGuardAuthorizer: WireGuardAuthorizer {
    let devices: Set<WireGuardPublicKey>

    func authorize(peer: WireGuardPublicKey) async -> WireGuardAuthorizedPeer? {
        guard devices.contains(peer) else { return nil }
        return WireGuardAuthorizedPeer(installID: peer.base64)
    }
}
