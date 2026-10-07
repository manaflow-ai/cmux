import CmuxBrowserStream
import Foundation
import Testing

@Suite("rd packetizer and reassembler")
struct ReassemblerTests {
    static func frame(_ number: UInt32, key: Bool, ref: UInt32? = nil, size: Int = 3000,
                      packetizer: inout RdPacketizer) throws -> [(RdDatagramHeader, Data)] {
        let body = RdFrameBody(captureMicros: UInt64(number), refFrame: key ? RdFrameBody.refNone : (ref ?? number - 1),
                               accessUnit: Data(repeating: UInt8(truncatingIfNeeded: number), count: size))
        return try packetizer.packetize(frame: number, flags: key ? .keyframe : [], body: body).map { try RdDatagramHeader.decode($0) }
    }

    @Test func framesReleaseInOrderEvenWithShardsReordered() throws {
        var packetizer = RdPacketizer(maxDatagram: 1200)
        var reassembler = RdReassembler()
        let first = try Self.frame(1, key: true, packetizer: &packetizer)
        let second = try Self.frame(2, key: false, packetizer: &packetizer)
        #expect(first.count == 3)
        var released: [UInt32] = []
        for (header, payload) in (second + first).reversed() {
            released += reassembler.push(header, payload: payload).map(\.frame)
        }
        #expect(released == [1, 2])
        #expect(reassembler.needsRecovery == false)
    }

    @Test func aLostFrameBreaksTheChainUntilAKeyframe() throws {
        var packetizer = RdPacketizer(maxDatagram: 1200)
        var reassembler = RdReassembler(holdFrames: 2)
        var released: [UInt32] = []
        for (h, p) in try Self.frame(1, key: true, packetizer: &packetizer) { released += reassembler.push(h, payload: p).map(\.frame) }
        // Frame 2 loses its middle shard.
        for (h, p) in try Self.frame(2, key: false, packetizer: &packetizer) where h.index != 1 {
            released += reassembler.push(h, payload: p).map(\.frame)
        }
        for number: UInt32 in 3...4 {
            for (h, p) in try Self.frame(number, key: false, packetizer: &packetizer) {
                released += reassembler.push(h, payload: p).map(\.frame)
            }
        }
        #expect(released == [1])
        #expect(reassembler.needsRecovery)
        #expect(reassembler.takeLosses() == [2, 3, 4])
        for (h, p) in try Self.frame(5, key: true, packetizer: &packetizer) { released += reassembler.push(h, payload: p).map(\.frame) }
        #expect(released == [1, 5])
        #expect(reassembler.needsRecovery == false)
    }

    @Test func aKeyframePastAGapReleasesAtOnce() throws {
        var packetizer = RdPacketizer(maxDatagram: 1200)
        var reassembler = RdReassembler(holdFrames: 4)
        for (h, p) in try Self.frame(1, key: true, packetizer: &packetizer) { _ = reassembler.push(h, payload: p) }
        _ = try Self.frame(2, key: false, packetizer: &packetizer)
        var released: [UInt32] = []
        for (h, p) in try Self.frame(3, key: true, packetizer: &packetizer) { released += reassembler.push(h, payload: p).map(\.frame) }
        #expect(released == [3])
        #expect(reassembler.takeLosses() == [2])
    }

    @Test func duplicateShardsFromBothLanesAreIgnored() throws {
        var packetizer = RdPacketizer(maxDatagram: 1200)
        var reassembler = RdReassembler()
        let shards = try Self.frame(1, key: true, packetizer: &packetizer)
        var released: [UInt32] = []
        for (h, p) in shards + shards { released += reassembler.push(h, payload: p).map(\.frame) }
        #expect(released == [1])
    }

    @Test func streamModeUsesFewLargeShards() throws {
        var packetizer = RdPacketizer(maxDatagram: RdPacketizer.streamDatagram)
        var reassembler = RdReassembler()
        let shards = try Self.frame(1, key: true, size: 40_000, packetizer: &packetizer)
        #expect(shards.count == 3)
        let out = shards.flatMap { reassembler.push($0.0, payload: $0.1) }
        #expect(out.first?.body.accessUnit.count == 40_000)
    }
}
