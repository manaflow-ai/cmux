import CmuxFuzzSupport
import CoreMedia
import Foundation
import Testing
@testable import CmuxNextPhone

/// The bytes `adb exec-out screenrecord --output-format=h264 -` writes come from
/// another device, in pipe chunks cut anywhere, and nothing checks them before
/// ``AnnexBParser`` and ``AndroidFrameAssembler`` do. Seeded property tests on
/// CmuxFuzzSupport (p10-stability-024; long mode: CMUX_FUZZ_SECONDS):
///
/// - the parser never traps and cuts the units of ``UnitModel``, which reads the
///   whole stream at once (every `00 00 01` starts a unit, ITU-T H.264 B.1.1), for
///   any chunking: one push, random chunks, one byte at a time;
/// - its allocation is bounded per unit: a unit longer than `maxUnitBytes` is
///   dropped, bytes before the first start code are not kept, and between calls it
///   holds at most `2 * (maxUnitBytes + 2)` bytes;
/// - the assembler never traps, and its samples are the frame units (types 1 and
///   5) it cut, in order, each one 4-byte length plus the unit.
@Suite struct AndroidStreamFuzzTests {
    /// Baseline profile, level 3.0, 320 x 240 (bits written by hand from H.264 7.3.2.1.1).
    static let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x05, 0x07, 0xE4]
    static let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    static let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x00, 0x03, 0x00, 0x21]
    static let slice: [UInt8] = [0x41, 0x9A, 0x02, 0x80]
    static let sei: [UInt8] = [0x06, 0x05, 0x01, 0x80]
    /// Start codes and NAL headers, for the mutator's token edits.
    static let tokens: [[UInt8]] = [[0, 0, 1], [0, 0, 0, 1], [0, 0], [0x67], [0x68], [0x65], [0x41], [0x06]]
    static let dictionary: [Data] = tokens.map { Data($0) }

    /// One input of either property, its choices read from `data` (the libFuzzer entry, p10-stability-182).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        let parser = rng.bool()
        let stream = StreamCase(&rng)
        if parser { try stream.checkParser(&rng) } else { try stream.checkAssembler(&rng) }
    }

    @Test func parserCutsTheModelsUnitsForAnyChunking() throws {
        let cases = try FuzzRun("AndroidStream.parser", seed: 0xA11D_5C7E_A000_0024, iterations: 20_000).forEach { rng in
            let stream = StreamCase(&rng)
            try stream.checkParser(&rng)
        }
        #expect(cases > 0)
    }

    @Test func assemblerSamplesAreTheFrameUnitsItCut() throws {
        try FuzzRun("AndroidStream.assembler", seed: 0xA11D_5C7E_A000_0025, iterations: 3_000).forEach { rng in
            let stream = StreamCase(&rng)
            try stream.checkAssembler(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("AndroidStream.oneInput", seed: 0xA11D, iterations: 512)
        // Choice tapes: the first byte picks the property (odd: parser), the next one the stream shape.
        let tapes: [[UInt8]] = [[0], [1], [1, 0], [0, 1], [1, 2, 3, 4]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
    }

    @Test func aUnitPastTheLimitIsDroppedAndItsBytesAreNotKept() {
        var parser = AnnexBParser(maxUnitBytes: 16)
        let big = [UInt8](repeating: 0x41, count: 4_096)
        var units = parser.append(Data([0, 0, 1] + Self.sps + [0, 0, 1]))
        for _ in 0..<64 {
            units += parser.append(Data(big))
            #expect(parser.bufferedByteCount <= 2 * (16 + 2))
        }
        units += parser.append(Data([0, 0, 1] + Self.slice + [0, 0, 1]))
        #expect(units.map { Array($0) } == [Self.sps, Self.slice])
    }

    @Test func bytesBeforeTheFirstStartCodeAreNotKept() {
        var parser = AnnexBParser()
        for _ in 0..<256 {
            #expect(parser.append(Data([UInt8](repeating: 0x55, count: 4_096))).isEmpty)
            #expect(parser.bufferedByteCount <= 2)
        }
        #expect(parser.flush() == nil)
    }

    @Test func theHandMadeStreamGivesOneSamplePerFrame() {
        let assembler = AndroidFrameAssembler()
        let frames: [[UInt8]] = [Self.idr, Self.slice, Self.slice]
        var stream: [UInt8] = [0, 0, 0, 1] + Self.sps + [0, 0, 0, 1] + Self.pps
        for frame in frames { stream += [0, 0, 1] + frame }
        stream += [0, 0, 0, 1]
        let samples = assembler.samples(from: Data(stream))
        #expect(samples.map { CMSampleBufferGetTotalSampleSize($0.buffer) } == frames.map { $0.count + 4 })
    }
}

extension AndroidStreamFuzzTests {
    /// What the parser must return for a whole stream, read at once: every `00 00 01` starts a unit,
    /// a unit ends where the next start code starts, its trailing zero bytes belong to no unit, an
    /// empty unit or one longer than `maxUnit` (before its zeros are trimmed) is dropped. `last` is
    /// the unit still open at the end, which only `flush()` returns.
    struct UnitModel: Equatable {
        var complete: [[UInt8]] = []
        var last: [UInt8]?

        init(_ stream: [UInt8], maxUnit: Int) {
            var codes: [Int] = []
            for index in stream.indices.dropLast(2) where stream[index...].starts(with: [0, 0, 1]) {
                codes.append(index)
            }
            func unit(_ range: Range<Int>) -> [UInt8]? {
                guard range.count <= maxUnit else { return nil }
                var end = range.upperBound
                while end > range.lowerBound, stream[end - 1] == 0 { end -= 1 }
                return end > range.lowerBound ? Array(stream[range.lowerBound..<end]) : nil
            }
            for (index, code) in codes.enumerated() where index + 1 < codes.count {
                if let found = unit((code + 3)..<codes[index + 1]) { complete.append(found) }
            }
            last = codes.last.flatMap { unit(($0 + 3)..<stream.count) }
        }
    }

    /// One stream and the parser limit it runs with.
    struct StreamCase {
        let bytes: [UInt8]
        let maxUnit: Int

        init(_ rng: inout FuzzRNG) {
            maxUnit = [0, 1, 4, 16, 64, 300, 4_096, AnnexBParser.defaultMaxUnitBytes][rng.below(8)]
            switch rng.below(6) {
            case 0:
                bytes = rng.bytes(count: rng.below(600))
            case 1:
                bytes = Self.valid(&rng)
            default:
                let mutator = FuzzMutator(dictionary: AndroidStreamFuzzTests.dictionary, maximumEdits: 6, maximumCount: 1 << 14)
                bytes = [UInt8](mutator.mutate(Data(Self.valid(&rng)), using: &rng))
            }
        }

        /// Units of every kind behind 3- and 4-byte start codes, now and then with leading junk,
        /// trailing zeros, a unit around the limit, or no final start code.
        static func valid(_ rng: inout FuzzRNG) -> [UInt8] {
            let units = [AndroidStreamFuzzTests.sps, AndroidStreamFuzzTests.pps, AndroidStreamFuzzTests.idr,
                         AndroidStreamFuzzTests.slice, AndroidStreamFuzzTests.sei]
            var out: [UInt8] = rng.oneIn(4) ? rng.bytes(count: rng.below(32)) : []
            for _ in 0..<(1 + rng.below(12)) {
                out += rng.bool() ? [0, 0, 1] : [0, 0, 0, 1]
                if rng.oneIn(5) {
                    // Payload bytes that never form a start code: a unit of a chosen length.
                    out += [0x41] + (0..<rng.below(5_000)).map { _ in UInt8(2 + rng.below(254)) }
                } else {
                    out += units[rng.below(units.count)]
                }
                if rng.oneIn(6) { out += [UInt8](repeating: 0, count: 1 + rng.below(3)) }
            }
            if rng.bool() { out += [0, 0, 0, 1] }
            return out
        }

        /// One push, then random chunks or single bytes, against the model and the bound.
        func checkParser(_ rng: inout FuzzRNG) throws {
            let expected = UnitModel(bytes, maxUnit: maxUnit)
            for feed in 0..<2 {
                var parser = AnnexBParser(maxUnitBytes: maxUnit)
                var got = UnitModel([], maxUnit: maxUnit)
                var at = 0
                while at < bytes.count {
                    let rest = bytes.count - at
                    let count = feed == 0 ? rest : (rng.oneIn(4) ? 1 : 1 + rng.below(min(rest, 2_048)))
                    let units = parser.append(Data(bytes[at..<(at + count)]))
                    at += count
                    try FuzzRun.check(units.allSatisfy { !$0.isEmpty && $0.count <= maxUnit }, "a unit is empty or past the limit")
                    try FuzzRun.check(
                        parser.bufferedByteCount <= 2 * (maxUnit + 2),
                        "the parser holds \(parser.bufferedByteCount) bytes with a \(maxUnit)-byte limit"
                    )
                    got.complete += units.map { Array($0) }
                }
                got.last = parser.flush().map { Array($0) }
                try FuzzRun.check(got == expected, "feed \(feed): \(Self.describe(got)) but the model \(Self.describe(expected)); \(describe())")
                try FuzzRun.check(parser.flush() == nil && parser.bufferedByteCount == 0, "flush left state behind")
            }
        }

        /// Random chunks through the assembler: its samples are its frame units, in order.
        func checkAssembler(_ rng: inout FuzzRNG) throws {
            let frames = UnitModel(bytes, maxUnit: AnnexBParser.defaultMaxUnitBytes).complete
                .filter { [1, 5].contains($0[0] & 0x1F) }
                .map { $0.count + 4 }
            let assembler = AndroidFrameAssembler()
            var sizes: [Int] = []
            var at = 0
            while at < bytes.count {
                let count = 1 + rng.below(min(bytes.count - at, 4_096))
                for sample in assembler.samples(from: Data(bytes[at..<(at + count)])) {
                    let buffer = sample.buffer
                    try FuzzRun.check(CMSampleBufferGetNumSamples(buffer) == 1, "a sample buffer holds \(CMSampleBufferGetNumSamples(buffer)) samples")
                    sizes.append(CMSampleBufferGetTotalSampleSize(buffer))
                }
                at += count
            }
            // A frame unit before any parameter sets has no format and makes no sample.
            var remaining = frames[...]
            let inOrder = sizes.allSatisfy { size in
                guard let index = remaining.firstIndex(of: size) else { return false }
                remaining = remaining[(index + 1)...]
                return true
            }
            try FuzzRun.check(inOrder, "sample sizes \(sizes) are not the frame units \(frames) in order; \(describe())")
        }

        static func describe(_ model: UnitModel) -> String {
            "cut \(model.complete.map(\.count)) and left \(model.last.map { "\($0.count)" } ?? "nothing")"
        }

        func describe() -> String {
            let shown = bytes.prefix(256).map { String(format: "%02x", $0) }.joined()
            return "limit \(maxUnit), \(bytes.count) bytes: \(shown)\(bytes.count > 256 ? "..." : "")"
        }
    }
}
