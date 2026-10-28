import CMUXMobileCore
import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxIrxTransport

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7): the
/// lane framers read bytes from a peer. Any byte stream, in any chunking, gives
/// whole frames, a typed error or a wait for more bytes; never a trap. Seeded
/// property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@Suite struct IrxFrameFuzzTests {
    /// One input of either property, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        if rng.bool() { try alignedChunking(&rng) } else { anyBytes(&rng) }
    }

    /// Forwarded bytes are whole frames of the stream, in order; every whole frame
    /// comes out unless an oversize header in the tail refused the stream.
    static func alignedChunking(_ rng: inout FuzzRNG) throws {
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
        try FuzzRun.check(stream.starts(with: forwarded), "forwarded bytes that are not a prefix of the stream")
        try FuzzRun.check(refused || forwarded.starts(with: wholeFrames), "a whole frame was held back")
    }

    static func anyBytes(_ rng: inout FuzzRNG) {
        var aligner = IrxEventFrameAligner(maximumFrameByteCount: rng.below(2) == 0 ? 0 : 1 << 20)
        for _ in 0..<(1 + rng.below(4)) {
            _ = try? aligner.append(rng.bytes(32))
        }
    }

    @Test func frameAlignerForwardsExactlyTheWholeFramesForAnyChunking() throws {
        try FuzzRun("IrxFrame.alignedChunking", seed: 0x61, iterations: 1_000).forEach { rng in
            try Self.alignedChunking(&rng)
        }
    }

    @Test func frameAlignerAcceptsAnyBytesOrRefuses() throws {
        try FuzzRun("IrxFrame.anyBytes", seed: 0x62, iterations: 2_000).forEach { rng in
            Self.anyBytes(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("IrxFrame.oneInput", seed: 0x63, iterations: 512)
        // Choice tapes, one per branch: even bytes go to anyBytes, odd ones to alignedChunking.
        try run.forEachInput(run.corpus(seeds: [Data([0]), Data([1])]), Self.oneInput)
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
