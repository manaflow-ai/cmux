import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrxTransport

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7): the
/// lane framers read bytes from a peer. Any byte stream, in any chunking, gives
/// whole frames, a typed error or a wait for more bytes; never a trap.
@Suite struct IrxFrameFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func bytes(_ limit: Int) -> Data {
            Data((0..<below(limit)).map { _ in UInt8(truncatingIfNeeded: next()) })
        }
    }

    @Test func frameAlignerForwardsExactlyTheWholeFramesForAnyChunking() throws {
        var rng = Rng(state: 0x61)
        for _ in 0..<1_000 {
            var stream = Data()
            for _ in 0..<rng.below(5) { stream += try MobileSyncFrameCodec.encodeFrame(rng.bytes(40)) }
            let wholeFrames = stream
            stream += rng.bytes(8) // a partial tail or noise
            var aligner = IrxEventFrameAligner(maximumFrameByteCount: 64)
            var forwarded = Data()
            var rest = stream[...]
            var refused = false
            while !rest.isEmpty {
                let chunk = rest.prefix(1 + rng.below(16))
                rest = rest.dropFirst(chunk.count)
                do {
                    if let block = try aligner.append(Data(chunk)) { forwarded += block }
                } catch IrxEventFrameAligner.Failure.frameTooLarge {
                    refused = true
                    break
                }
            }
            // Forwarded bytes are whole frames of the stream, in order; every whole
            // frame comes out unless an oversize header in the tail refused the stream.
            #expect(stream.starts(with: forwarded))
            #expect(refused || forwarded.starts(with: wholeFrames))
        }
    }

    @Test func frameAlignerAcceptsAnyBytesOrRefuses() {
        var rng = Rng(state: 0x62)
        for _ in 0..<2_000 {
            var aligner = IrxEventFrameAligner(maximumFrameByteCount: rng.below(2) == 0 ? 0 : 1 << 20)
            for _ in 0..<(1 + rng.below(4)) {
                _ = try? aligner.append(rng.bytes(32))
            }
        }
    }

    @Test func controlFrameCodecRefusesOversizeAndRoundTripsJSON() throws {
        struct Message: Codable, Equatable { var text: String }
        let encoded = try IrxFrameCodec().encode(Message(text: "hello"))
        let length = encoded.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(length == encoded.count - 4)
        #expect(try IrxFrameCodec().decode(Message.self, from: encoded.dropFirst(4)) == Message(text: "hello"))
        let huge = Message(text: String(repeating: "x", count: IrxProtocol().maximumControlFrameByteCount))
        #expect(throws: IrxFrameCodecError.self) { try IrxFrameCodec().encode(huge) }
    }
}
