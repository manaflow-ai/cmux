import CmuxLink
@_spi(Testing) import CmuxLinkDirect
import Foundation
import Testing

@Suite("Direct transport over localhost", .serialized)
struct TransportTests {
    @Test("mutual authentication: both ends see the other's pinned key, path is direct")
    func authenticated() async throws {
        let pair = try await LocalhostPair()
        let dialed = try await pair.carrier().connect(to: pair.peer())
        let accepted = try #require(await firstIncoming(pair.acceptor))
        let dialer = try #require(dialed as? DirectTransport)
        let host = try #require(accepted as? DirectTransport)
        #expect(dialer.remoteKey == pair.host.publicKey)
        #expect(host.remoteKey == pair.device.publicKey)
        #expect(await dialer.path == LinkPath(kind: .direct, carrier: .direct))
        await dialer.close()
        await host.close()
        await pair.acceptor.stop()
    }

    @Test("frames cross both ways, large frames reassemble, close is graceful and once")
    func framesAndClose() async throws {
        let pair = try await LocalhostPair()
        let dialer = try await pair.carrier().connect(to: pair.peer())
        let host = try #require(await firstIncoming(pair.acceptor))
        let big = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try await dialer.send(TransportFrame(lane: .control, bytes: Data("hello".utf8)))
        try await dialer.send(TransportFrame(lane: TransportLane(reliability: .reliableOrdered, priority: .bulk), bytes: big))
        try await host.send(TransportFrame(lane: .control, bytes: Data("back".utf8)))
        await dialer.close()
        await #expect(throws: DirectTransportError.closed) {
            try await dialer.send(TransportFrame(lane: .control, bytes: Data()))
        }

        var hostFrames: [Data] = []
        var hostClosed: [TransportCloseReason] = []
        for await event in host.events {
            switch event {
            case let .frame(frame): hostFrames.append(frame.bytes)
            case let .closed(reason): hostClosed.append(reason)
            default: break
            }
        }
        #expect(hostFrames == [Data("hello".utf8), big])
        #expect(hostClosed == [.remote])

        var dialerClosed: [TransportCloseReason] = []
        var sawRTT = false
        for await event in dialer.events {
            if case let .closed(reason) = event { dialerClosed.append(reason) }
            if case .rtt = event { sawRTT = true }
        }
        #expect(dialerClosed.count == 1)
        #expect(sawRTT)
        await #expect(throws: DirectTransportError.frameTooLarge(256 * 1024 + 1)) {
            try await host.send(TransportFrame(lane: .control, bytes: Data(count: 256 * 1024 + 1)))
        }
        await pair.acceptor.stop()
    }

    @Test("a dialer pinning the wrong host key is refused")
    func wrongHostKey() async throws {
        let pair = try await LocalhostPair()
        await #expect(throws: DirectCarrierError.handshakeRefused) {
            try await pair.carrier().connect(to: pair.peer(hostKey: DirectIdentity().publicKey))
        }
        #expect(pair.injector.liveCount == 0)
        await pair.acceptor.stop()
    }

    @Test("a device the host has not paired is refused")
    func unauthorizedDevice() async throws {
        let pair = try await LocalhostPair()
        await #expect(throws: DirectCarrierError.handshakeRefused) {
            try await pair.carrier(identity: DirectIdentity()).connect(to: pair.peer())
        }
        #expect(pair.injector.liveCount == 0)
        await pair.acceptor.stop()
    }

    @Test("dialing the wrong host id is refused")
    func wrongHostID() async throws {
        let pair = try await LocalhostPair()
        await #expect(throws: DirectCarrierError.handshakeRefused) {
            try await pair.carrier().connect(to: pair.peer(hostID: "someone-else"))
        }
        await pair.acceptor.stop()
    }

    @Test("a port with no listener fails without hanging")
    func nothingListening() async throws {
        let pair = try await LocalhostPair()
        let peer = pair.peer()
        await pair.acceptor.stop()
        await #expect(throws: DirectCarrierError.self) {
            try await pair.carrier().connect(to: peer)
        }
    }

    @Test("a dropped socket ends both transports with pathLost")
    func drop() async throws {
        let pair = try await LocalhostPair()
        let dialer = try await pair.carrier().connect(to: pair.peer())
        let host = try #require(await firstIncoming(pair.acceptor))
        pair.injector.dropAll()
        for transport in [dialer, host] {
            var reasons: [TransportCloseReason] = []
            for await event in transport.events {
                if case let .closed(reason) = event { reasons.append(reason) }
            }
            #expect(reasons.count == 1)
            guard case .pathLost = reasons.first else {
                Issue.record("expected pathLost, got \(reasons)")
                continue
            }
        }
        await pair.acceptor.stop()
    }

    private func firstIncoming(_ acceptor: DirectAcceptor) async -> (any LinkTransport)? {
        for await transport in acceptor.incoming { return transport }
        return nil
    }
}
