import CmuxLink
import CmuxLinkTesting
import Foundation
import os
import Testing

/// `LinkTransport.peerIdentity` reaches the session, and `LinkHost` never
/// resumes a session on a transport that proved another key.
@Suite("Peer identity")
struct PeerIdentityTests {
    static let device = LinkPeerIdentity(carrier: .webrtc, keyKind: .p256, publicKey: Data(repeating: 1, count: 65))
    static let intruder = LinkPeerIdentity(carrier: .webrtc, keyKind: .p256, publicKey: Data(repeating: 2, count: 65))
    static let host = LinkPeerIdentity(carrier: .webrtc, keyKind: .p256, publicKey: Data(repeating: 3, count: 65))

    @Test("both sessions expose the carrier-authenticated peer")
    func exposesIdentity() async throws {
        let rig = try await IdentityRig()
        let hostSession = try await rig.nextHostSession()
        #expect(await hostSession.peerIdentity == Self.device)
        #expect(await rig.dialer.peerIdentity == Self.host)
        await rig.shutdown()
    }

    @Test("a transport with another key cannot resume the session")
    func refusesOtherKey() async throws {
        let rig = try await IdentityRig()
        let hostSession = try await rig.nextHostSession()
        rig.claimed.withLock { $0 = Self.intruder }
        await rig.network.dropAll()
        try await SessionTestPair.waitFor(rig.dialer) { !$0.isLive }
        // Every reconnect now presents the intruder key and is refused.
        let refused = try await SessionTestPair.within(.seconds(5)) {
            for await count in rig.refusals.stream where count >= 2 { return count }
            return 0
        }
        #expect(refused >= 2)
        #expect(await rig.dialer.state.isLive == false)
        #expect(await hostSession.peerIdentity == Self.device)

        rig.claimed.withLock { $0 = Self.device }
        try await SessionTestPair.waitFor(rig.dialer) { $0.isLive }
        #expect(await rig.host.activeSessionCount == 1)
        #expect(await hostSession.state.isLive)
        await rig.shutdown()
    }
}

/// A loopback pair whose host-side transports carry the identity the dialer
/// currently claims, and whose dialer-side transports carry the host's.
private struct IdentityRig {
    let network: LoopbackNetwork
    let host: LinkHost
    let dialer: LinkSession
    let claimed: OSAllocatedUnfairLock<LinkPeerIdentity>
    let refusals: RefusalCounter
    private let hostSessions: AsyncQueue<LinkSession>

    init() async throws {
        let network = LoopbackNetwork()
        let claimed = OSAllocatedUnfairLock(initialState: PeerIdentityTests.device)
        let refusals = RefusalCounter()
        let acceptor = IdentifiedAcceptor(inner: network.acceptor, claimed: claimed, refusals: refusals)
        let host = LinkHost(acceptor: acceptor, configuration: SessionTestPair.fast)
        await host.start()
        let hostSessions = AsyncQueue<LinkSession>()
        let sessions = await host.sessions()
        Task { for await session in sessions { await hostSessions.push(session) } }
        let carrier = IdentifiedCarrier(inner: network.carrier(kind: .webrtc, path: .p2p), identity: PeerIdentityTests.host)
        let dialer = LinkSession(
            peer: LinkPeer(hostID: "host"),
            selector: PathSelector(carriers: [carrier], policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
            configuration: SessionTestPair.fast
        )
        self.network = network
        self.host = host
        self.dialer = dialer
        self.claimed = claimed
        self.refusals = refusals
        self.hostSessions = hostSessions
        await dialer.connect()
        try await SessionTestPair.waitFor(dialer) { $0.isLive }
    }

    func nextHostSession() async throws -> LinkSession {
        let queue = hostSessions
        return try await SessionTestPair.within(.seconds(5)) { try #require(await queue.next()) }
    }

    func shutdown() async {
        await dialer.close()
        await host.close()
    }
}

/// Counts host-side transports that ended without carrying a session.
private final class RefusalCounter: Sendable {
    let stream: AsyncStream<Int>
    private let sink: AsyncStream<Int>.Continuation
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init() {
        (stream, sink) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
    }

    func record() {
        sink.yield(count.withLock { $0 += 1; return $0 })
    }
}

private struct IdentifiedCarrier: LinkCarrier {
    let inner: LoopbackCarrier
    let identity: LinkPeerIdentity
    var kind: CarrierKind { inner.kind }
    var candidatePaths: [PathKind] { inner.candidatePaths }

    func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        IdentifiedTransport(inner: try await inner.connect(to: peer), peerIdentity: identity, onRefused: nil)
    }
}

private struct IdentifiedAcceptor: LinkAcceptor {
    let incoming: AsyncStream<any LinkTransport>

    init(inner: LoopbackAcceptor, claimed: OSAllocatedUnfairLock<LinkPeerIdentity>, refusals: RefusalCounter) {
        let source = inner.incoming
        let (stream, continuation) = AsyncStream.makeStream(of: (any LinkTransport).self)
        incoming = stream
        Task {
            for await transport in source {
                let identity = claimed.withLock { $0 }
                var refused: (@Sendable () -> Void)?
                if identity == PeerIdentityTests.intruder { refused = { refusals.record() } }
                continuation.yield(IdentifiedTransport(inner: transport, peerIdentity: identity, onRefused: refused))
            }
            continuation.finish()
        }
    }
}

/// Forwards to a loopback transport and adds an identity. `onRefused` runs
/// when the host closes the transport (the refusal path).
private final class IdentifiedTransport: LinkTransport {
    let inner: any LinkTransport
    let peerIdentity: LinkPeerIdentity?
    private let onRefused: (@Sendable () -> Void)?

    init(inner: any LinkTransport, peerIdentity: LinkPeerIdentity, onRefused: (@Sendable () -> Void)?) {
        self.inner = inner
        self.peerIdentity = peerIdentity
        self.onRefused = onRefused
    }

    var path: LinkPath { get async { await inner.path } }
    var capabilities: TransportCapabilities { inner.capabilities }
    var events: AsyncStream<TransportEvent> { inner.events }
    func send(_ frame: TransportFrame) async throws { try await inner.send(frame) }
    func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        try await inner.publishMediaTrack(descriptor)
    }

    func close() async {
        onRefused?()
        await inner.close()
    }
}
