import CmuxLink
import CmuxLinkTesting
@testable import CmuxLinkWG
import CmuxLinkWGTesting
import Foundation
import Testing

@Suite("WebRTC-WG transport", .serialized)
struct TransportTests {
    static let reliable = TransportLane(reliability: .reliableOrdered, priority: .render)

    static func payload(_ index: Int, size: Int = 64) -> Data {
        var data = Data(repeating: UInt8(truncatingIfNeeded: index), count: size)
        withUnsafeBytes(of: UInt32(index).littleEndian) { data.replaceSubrange(0..<4, with: $0) }
        return data
    }

    @Test func connectsBothWaysWithLargeFrames() async throws {
        let pair = try await TransportPair.connect()
        let hostLog = EventLog(pair.host)
        let dialerLog = EventLog(pair.dialer)
        #expect(await pair.dialer.path == LinkPath(kind: .p2p, carrier: .webrtcWireGuard))
        let big = Self.payload(1, size: 256 * 1024)
        try await pair.dialer.send(TransportFrame(lane: Self.reliable, bytes: big))
        try await pair.host.send(TransportFrame(lane: Self.reliable, bytes: Self.payload(2)))
        await hostLog.waitForFrames(1)
        await dialerLog.waitForFrames(1)
        #expect(await hostLog.frames == [big])
        #expect(await dialerLog.frames == [Self.payload(2)])
        await pair.shutdown()
    }

    @Test func gracefulCloseDeliversEverythingFirst() async throws {
        let pair = try await TransportPair.connect()
        let hostLog = EventLog(pair.host)
        for index in 0..<50 {
            try await pair.dialer.send(TransportFrame(lane: Self.reliable, bytes: Self.payload(index)))
        }
        let start = ContinuousClock.now
        await pair.dialer.close()
        #expect(ContinuousClock.now - start < .seconds(1), "close needs acks, not the timeout")
        await hostLog.waitForFrames(50)
        #expect(await hostLog.frames == (0..<50).map { Self.payload($0) })
        await pair.acceptor.stop()
    }

    @Test func unauthorizedDeviceGetsNoAnswer() async throws {
        let network = InMemoryUnderlayNetwork()
        let hostKey = WireGuardPrivateKey()
        let acceptor = WireGuardOverWebRTCAcceptor(
            identity: hostKey, hostID: "host-1", underlays: network,
            authorizer: WireGuardPinnedAuthorizer(peers: [:])
        )
        await acceptor.start()
        let configuration = WireGuardLinkConfiguration(connectTimeout: .milliseconds(300))
        let carrier = WireGuardOverWebRTCCarrier(
            identity: WireGuardPrivateKey(), installID: "stranger", underlays: network, configuration: configuration
        )
        let peer = LinkPeer(hostID: "host-1", hints: WireGuardHintsResolver().hints(for: hostKey.publicKey))
        await #expect(throws: WireGuardCarrierError.handshakeTimeout) {
            _ = try await carrier.connect(to: peer)
        }
        #expect(await acceptor.liveTransportCount == 0)
        await acceptor.stop()
    }

    @Test func missingHostKeyFailsBeforeDialing() async throws {
        let network = InMemoryUnderlayNetwork()
        let carrier = WireGuardOverWebRTCCarrier(identity: WireGuardPrivateKey(), installID: "d", underlays: network)
        await #expect(throws: WireGuardCarrierError.missingHostKey(hostID: "h")) {
            _ = try await carrier.connect(to: LinkPeer(hostID: "h"))
        }
        #expect(await network.openCount == 0)
    }

    @Test func icePathChangeKeepsTheSession() async throws {
        let pair = try await TransportPair.connect()
        let dialerLog = EventLog(pair.dialer)
        let hostLog = EventLog(pair.host)
        let index = await pair.dialer.currentSessionIndex
        await pair.network.changePath(to: .turn)
        try await pair.dialer.send(TransportFrame(lane: Self.reliable, bytes: Self.payload(1)))
        await hostLog.waitForFrames(1)
        #expect(await dialerLog.paths == [.turn])
        #expect(await pair.dialer.path.kind == .turn)
        #expect(await pair.dialer.currentSessionIndex == index)
        #expect(await pair.network.openCount == 1)
        await pair.shutdown()
    }

    /// The peer connection dies mid-stream: the dialer opens a new underlay,
    /// the host routes it to the live session by its WireGuard index, and
    /// every reliable frame arrives once, in order, with no new handshake.
    @Test func underlayReplacementKeepsTheWireGuardSession() async throws {
        let conditions = UnderlayConditions(latency: .milliseconds(1), jitter: .milliseconds(2), loss: 0.02, seed: 0x40A)
        let pair = try await TransportPair.connect(conditions: conditions)
        let hostLog = EventLog(pair.host)
        let dialerLog = EventLog(pair.dialer)
        let dialerIndex = await pair.dialer.currentSessionIndex
        let hostIndex = await pair.host.currentSessionIndex
        let total = 300
        let sender = Task {
            for index in 0..<total {
                try await pair.dialer.send(TransportFrame(lane: Self.reliable, bytes: Self.payload(index, size: 3000)))
            }
        }
        await hostLog.waitForFrames(100)
        await pair.network.roam(to: .turn)
        try await sender.value
        await hostLog.waitForFrames(total)
        #expect(await hostLog.frames == (0..<total).map { Self.payload($0, size: 3000) })
        #expect(await pair.network.openCount == 2, "one new underlay")
        #expect(await pair.dialer.currentSessionIndex == dialerIndex, "no new handshake")
        #expect(await pair.host.currentSessionIndex == hostIndex)
        #expect(await pair.acceptor.liveTransportCount == 1)
        #expect(await dialerLog.paths.last == .turn)
        #expect(await pair.dialer.path.kind == .turn)
        #expect(await hostLog.closed == nil)
        await pair.shutdown()
    }

    @Test func noUnderlayWithinTheRebindWindowEndsTheTransport() async throws {
        let configuration = WireGuardLinkConfiguration(rebindWindow: .milliseconds(200))
        let pair = try await TransportPair.connect(configuration: configuration)
        let dialerLog = EventLog(pair.dialer)
        let hostLog = EventLog(pair.host)
        await pair.network.refuseOpens(true)
        await pair.network.roam(to: .turn)
        for log in [dialerLog, hostLog] {
            let reason = await log.waitForClose()
            guard case .pathLost = reason else {
                Issue.record("expected pathLost, got \(reason)")
                continue
            }
        }
        await pair.acceptor.stop()
    }

    @Test func unacknowledgedDataMeansADeadPath() async throws {
        let pair = try await TransportPair.connect(configuration: WireGuardLinkConfiguration(deadPathTimeout: .milliseconds(300)))
        let dialerLog = EventLog(pair.dialer)
        await pair.network.setConditions(UnderlayConditions(loss: 1))
        try await pair.dialer.send(TransportFrame(lane: Self.reliable, bytes: Self.payload(1)))
        guard case .pathLost = await dialerLog.waitForClose() else {
            Issue.record("expected pathLost")
            return
        }
        await pair.acceptor.stop()
    }

    @Test func resetEndsTheTransport() async throws {
        let pair = try await TransportPair.connect()
        let dialerLog = EventLog(pair.dialer)
        await pair.network.reset()
        _ = await dialerLog.waitForClose()
        #expect(await pair.network.openCount == 1, "a reset never rebinds")
        await pair.acceptor.stop()
    }

    /// Short WireGuard timers: the session rekeys several times under
    /// continuous traffic and no frame is lost or reordered.
    @Test func rekeyUnderTrafficIsInvisibleToLanes() async throws {
        let timers = WireGuardTimers(
            rekeyAfterTime: .milliseconds(150), rejectAfterTime: .seconds(2),
            rekeyAttemptTime: .seconds(2), rekeyTimeout: .milliseconds(200), keepaliveTimeout: .milliseconds(500)
        )
        let pair = try await TransportPair.connect(
            conditions: UnderlayConditions(latency: .milliseconds(1)),
            configuration: WireGuardLinkConfiguration(timers: timers)
        )
        let hostLog = EventLog(pair.host)
        var indices: Set<UInt32> = []
        let total = 120
        for index in 0..<total {
            try await pair.dialer.send(TransportFrame(lane: Self.reliable, bytes: Self.payload(index)))
            if let current = await pair.dialer.currentSessionIndex { indices.insert(current) }
            try await Task.sleep(for: .milliseconds(5))
        }
        await hostLog.waitForFrames(total)
        #expect(await hostLog.frames == (0..<total).map { Self.payload($0) })
        #expect(indices.count >= 3, "rekeyed under traffic (\(indices.count) keypairs)")
        #expect(await hostLog.closed == nil)
        #expect(await pair.network.openCount == 1)
        await pair.shutdown()
    }

    @Test func unreliableLanesFragmentAndDeliver() async throws {
        let pair = try await TransportPair.connect()
        let hostLog = EventLog(pair.host)
        let lane = TransportLane(reliability: .unreliableUnordered, priority: .media)
        let frame = Self.payload(5, size: 10_000)
        try await pair.dialer.send(TransportFrame(lane: lane, bytes: frame))
        await hostLog.waitForFrames(1)
        #expect(await hostLog.frames == [frame])
        await pair.shutdown()
    }

    @Test func mediaTracksAreRefused() async throws {
        let pair = try await TransportPair.connect()
        #expect(pair.dialer.capabilities.carriesMedia == false)
        await #expect(throws: WireGuardCarrierError.mediaUnsupported) {
            _ = try await pair.dialer.publishMediaTrack(MediaTrackDescriptor(id: "v", kind: .video, label: "x"))
        }
        await pair.shutdown()
    }
}

