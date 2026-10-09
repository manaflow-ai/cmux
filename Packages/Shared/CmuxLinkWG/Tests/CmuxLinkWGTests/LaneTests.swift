import CmuxLink
@testable import CmuxLinkWG
import Testing

@Suite("Lanes and overlay")
struct LaneTests {
    @Test func laneFramesRoundTrip() {
        let lane = LaneID(kind: .reliable, priority: .render)
        let frames: [LaneFrame] = [
            .reliable(lane: lane, seq: 7, first: true, last: false, payload: [1, 2, 3]),
            .message(lane: LaneID(kind: .partial, priority: .media), id: 9, index: 1, count: 3, lifetimeMillis: 50, payload: [4]),
            .ack(lane: lane, next: 12, sack: 0b1011, consumed: nil),
            .ack(lane: lane, next: 12, sack: 0b1011, consumed: 9),
            .close,
            .closeAck,
        ]
        for frame in frames { #expect(LaneFrame.decode(frame.encode()) == frame) }
        #expect(LaneFrame.decode([2, 1]) == nil, "unknown version")
        #expect(LaneFrame.decode([1, 2, lane.byte]) == nil, "short ack")
    }

    @Test func overlayDatagramChecksumAndPadding() {
        let datagram = OverlayDatagram(
            source: OverlayAddress(id: "device"), destination: OverlayAddress(id: "host"), payload: [UInt8](0..<37)
        )
        var packet = datagram.encode()
        #expect(packet.count == 48 + 37)
        #expect(OverlayAddress(id: "host").description.hasPrefix("fd7c:6d78:"))
        packet += [0, 0, 0]
        #expect(OverlayDatagram.decode(packet) == datagram, "WireGuard padding after the payload is ignored")
        packet[60] ^= 1
        #expect(OverlayDatagram.decode(packet) == nil, "a corrupted payload fails the UDP checksum")
    }

    @Test func reliableLaneSurvivesLossReorderAndDuplication() {
        let lane = LaneID(kind: .reliable, priority: .bulk)
        var sender = ReliableSender(lane: lane)
        var receiver = ReliableReceiver(windowFragments: 4096)
        var timer = RetransmitTimer(minimum: .milliseconds(50), maximum: .seconds(2))
        let frames = (0..<40).map { index in [UInt8](repeating: UInt8(index), count: 50 + index * 37) }
        var queue: [UInt32] = []
        for frame in frames { queue += sender.enqueue(frame, maxPayload: 100) }

        var generator = SplitMix(seed: 7)
        var now = Duration.zero
        var delivered: [[UInt8]] = []
        var rounds = 0
        while !sender.isDrained, rounds < 500 {
            rounds += 1
            var wire: [[UInt8]] = []
            for seq in queue {
                guard let frame = sender.transmit(seq, now: now) else { continue }
                if generator.unit() < 0.2 { continue }
                wire.append(frame)
                if generator.unit() < 0.1 { wire.append(frame) }
            }
            queue.removeAll()
            wire.shuffle(using: &generator)
            now += .milliseconds(10)
            for bytes in wire {
                guard case let .reliable(_, seq, first, last, payload)? = LaneFrame.decode(bytes) else { continue }
                delivered += receiver.receive(seq: seq, first: first, last: last, payload: payload)
                if generator.unit() < 0.2 { continue }
                let ack = receiver.ack
                let result = sender.acknowledge(next: ack.next, sack: ack.sack, now: now, smoothedRTT: timer.smoothed)
                if let rtt = result.rtt { timer.sample(rtt) }
                queue += result.retransmit
            }
            now += timer.timeout
            queue += sender.expired(now: now, timeout: timer.timeout)
        }
        #expect(sender.isDrained)
        #expect(delivered == frames)
    }

    @Test func messagesReassembleOutOfOrder() {
        var reassembler = MessageReassembler(limit: 2)
        #expect(reassembler.receive(id: 1, index: 1, count: 2, payload: [2]) == nil)
        #expect(reassembler.receive(id: 1, index: 0, count: 2, payload: [1]) == [1, 2])
        #expect(reassembler.receive(id: 5, index: 0, count: 1, payload: [9]) == [9])
        // Oldest incomplete messages are dropped past the limit.
        _ = reassembler.receive(id: 10, index: 0, count: 2, payload: [1])
        _ = reassembler.receive(id: 11, index: 0, count: 2, payload: [1])
        _ = reassembler.receive(id: 12, index: 0, count: 2, payload: [1])
        #expect(reassembler.receive(id: 10, index: 1, count: 2, payload: [2]) == nil)
        #expect(reassembler.receive(id: 12, index: 1, count: 2, payload: [2]) == [1, 2])
    }
}

/// SplitMix64 for the pure lane simulation.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
