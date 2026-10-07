import CmuxLink
import CmuxLinkWG
import CmuxLinkWGTesting
import Foundation

/// A V2 carrier and acceptor on one in-memory network, connected.
struct TransportPair {
    let network: InMemoryUnderlayNetwork
    let acceptor: WireGuardOverWebRTCAcceptor
    let carrier: WireGuardOverWebRTCCarrier
    let peer: LinkPeer
    let dialer: WireGuardLinkTransport
    let host: WireGuardLinkTransport

    static func connect(
        conditions: UnderlayConditions = .perfect,
        configuration: WireGuardLinkConfiguration = WireGuardLinkConfiguration()
    ) async throws -> TransportPair {
        let network = InMemoryUnderlayNetwork(conditions: conditions)
        let hostKey = WireGuardPrivateKey()
        let deviceKey = WireGuardPrivateKey()
        let acceptor = WireGuardOverWebRTCAcceptor(
            identity: hostKey, hostID: "host-1", underlays: network,
            authorizer: WireGuardPinnedAuthorizer(peers: [deviceKey.publicKey: "device-1"]),
            configuration: configuration
        )
        await acceptor.start()
        let carrier = WireGuardOverWebRTCCarrier(
            identity: deviceKey, installID: "device-1", underlays: network, configuration: configuration
        )
        let peer = LinkPeer(hostID: "host-1", hints: WireGuardHintsResolver().hints(for: hostKey.publicKey))
        let dialer = try await carrier.connectTransport(to: peer)
        var accepted: (any LinkTransport)?
        for await transport in acceptor.incoming {
            accepted = transport
            break
        }
        guard let host = accepted as? WireGuardLinkTransport else { throw TransportPairError.noHostTransport }
        return TransportPair(network: network, acceptor: acceptor, carrier: carrier, peer: peer, dialer: dialer, host: host)
    }

    func shutdown() async {
        await dialer.close()
        await acceptor.stop()
    }
}

enum TransportPairError: Error {
    case noHostTransport
}

/// Collects a transport's events in a background task.
actor EventLog {
    private(set) var frames: [Data] = []
    private(set) var paths: [PathKind] = []
    private(set) var closed: TransportCloseReason?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var closeWaiters: [CheckedContinuation<TransportCloseReason, Never>] = []

    init(_ transport: any LinkTransport) {
        let events = transport.events
        Task { [weak self] in
            for await event in events { await self?.record(event) }
        }
    }

    private func record(_ event: TransportEvent) {
        switch event {
        case let .frame(frame): frames.append(frame.bytes)
        case let .pathChanged(path): paths.append(path.kind)
        case let .closed(reason):
            closed = reason
            for waiter in closeWaiters { waiter.resume(returning: reason) }
            closeWaiters.removeAll()
        default: break
        }
        let ready = waiters.filter { $0.count <= frames.count }
        waiters.removeAll { $0.count <= frames.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForClose() async -> TransportCloseReason {
        if let closed { return closed }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    func waitForFrames(_ count: Int) async {
        guard frames.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
