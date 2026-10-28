import CmuxFuzzSupport
import CoreMedia
import Foundation
import Testing
@testable import CmuxNextRemoteView

/// A remote host's access units and stream-carrier bytes reach ``RemoteAnnexB``,
/// ``RemoteVideoFormat`` and ``RemoteRdStreamSplitter`` before anything else
/// looks at them. Seeded property tests on CmuxFuzzSupport
/// (long mode: CMUX_FUZZ_SECONDS):
///
/// - ``RemoteAnnexB`` never traps and gives exactly what ``NALModel`` reads from
///   the spec (every `00 00 01` starts a NAL unit, ITU-T H.264 B.1.1 and H.265
///   B.2.1; the NAL type tables, H.264 Table 7-1 and H.265 Table 7-1). Its output
///   per access unit is bounded: at most one 4-byte length per 3-byte start code
///   more than the input;
/// - Core Media takes any parameter sets and NAL bytes it hands on, without a trap;
/// - the splitter's pieces are the input, none empty (an empty push is a null
///   pointer to the core, which ends the session), cut exactly where the
///   ``CarrierModel`` says a control frame ends, for any chunking.
@Suite nonisolated struct RemoteAnnexBFuzzTests {
    /// Start codes, NAL headers of both codecs and stream-frame headers, for the mutator's token edits.
    static let tokens: [[UInt8]] = [
        [0, 0, 1], [0, 0, 0, 1], [0x67], [0x68], [0x65], [0x41], [0x09], [0x40, 0x01], [0x42, 0x01], [0x44, 0x01],
        [0x26, 0x01], [0x46, 0x01], [1, 0, 0, 0, 0], [2, 4, 0, 0, 0], [3, 0xFF, 0xFF, 0xFF, 0xFF],
    ]
    static let dictionary: [Data] = tokens.map { Data($0) }

    /// One input of a property, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(3) {
        case 0: try annexB(&rng)
        case 1: formats(&rng)
        default: try splitter(&rng)
        }
    }

    @Test func annexBMatchesTheSpecModel() throws {
        try FuzzRun("RemoteAnnexB.parse", seed: 0x0A22_EB00_0000_0024, iterations: 20_000).forEach { rng in
            try Self.annexB(&rng)
        }
    }

    @Test func coreMediaTakesAnyParameterSets() throws {
        try FuzzRun("RemoteAnnexB.formats", seed: 0x0A22_EB00_0000_0025, iterations: 3_000).forEach { rng in
            Self.formats(&rng)
        }
    }

    @Test func splitterCutsAfterEveryControlFrame() throws {
        try FuzzRun("RemoteRdStreamSplitter.split", seed: 0x0A22_EB00_0000_0026, iterations: 20_000).forEach { rng in
            try Self.splitter(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("RemoteAnnexB.oneInput", seed: 0x0A22, iterations: 512)
        // Choice tapes: the first byte picks the property (0 Annex-B, 1 Core Media, 2 splitter).
        let tapes: [[UInt8]] = [[0], [1], [2], [0, 1, 2, 3], [2, 2, 2]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
    }

    // MARK: - Annex-B

    static func annexB(_ rng: inout FuzzRNG) throws {
        let codec: RemoteVideoCodec = rng.bool() ? .h264 : .hevc
        let input = accessUnit(codec: codec, &rng)
        let model = NALModel(input, codec: codec)
        let annexB = RemoteAnnexB()
        let ranges = annexB.nalRanges(input)
        try FuzzRun.check(ranges == model.ranges, "\(codec) ranges \(ranges) but the model \(model.ranges); \(describe(input))")
        let parsed = annexB.parse(input, codec: codec)
        try FuzzRun.check(parsed == model.parsed, "\(codec) parse differs from the model; \(describe(input))")
        try FuzzRun.check(
            parsed.lengthPrefixed.count <= input.count + input.count / 3 + 1,
            "\(input.count) input bytes gave \(parsed.lengthPrefixed.count) output bytes"
        )
        try FuzzRun.check(parsed.parameterSets.reduce(0) { $0 + $1.count } <= input.count, "parameter sets larger than the input")
    }

    /// An access unit as a host sends it (parameter sets, delimiters and slices behind 3- and 4-byte
    /// start codes), random bytes, or one of those mutated.
    static func accessUnit(codec: RemoteVideoCodec, _ rng: inout FuzzRNG) -> [UInt8] {
        switch rng.below(5) {
        case 0: return rng.bytes(count: rng.below(512))
        case 1: return validAccessUnit(codec: codec, &rng)
        default:
            let mutator = FuzzMutator(dictionary: dictionary, maximumEdits: 6, maximumCount: 1 << 14)
            return [UInt8](mutator.mutate(Data(validAccessUnit(codec: codec, &rng)), using: &rng))
        }
    }

    static func validAccessUnit(codec: RemoteVideoCodec, _ rng: inout FuzzRNG) -> [UInt8] {
        // H.264: AUD, SPS, PPS, SEI, IDR, non-IDR. HEVC (two-byte headers): AUD, VPS, SPS, PPS, IDR, CRA, TRAIL.
        let headers: [[UInt8]] = switch codec {
        case .h264: [[0x09], [0x67], [0x68], [0x06], [0x65], [0x41]]
        case .hevc: [[0x46, 0x01], [0x40, 0x01], [0x42, 0x01], [0x44, 0x01], [0x26, 0x01], [0x2A, 0x01], [0x02, 0x01]]
        }
        var out: [UInt8] = []
        for _ in 0..<(1 + rng.below(8)) {
            out += rng.bool() ? [0, 0, 0, 1] : [0, 0, 1]
            out += headers[rng.below(headers.count)]
            // Payload bytes never form a start code; a unit now and then ends in trailing zeros.
            out += (0..<rng.below(200)).map { _ in UInt8(1 + rng.below(255)) }
            if rng.oneIn(5) { out += [UInt8](repeating: 0, count: 1 + rng.below(3)) }
        }
        return out
    }

    /// What ``RemoteAnnexB`` must return, read from the spec: a NAL unit runs from after its start code
    /// to the next start code, without the zero bytes before that one; the last runs to the end.
    nonisolated struct NALModel {
        var ranges: [Range<Int>] = []
        var parsed = RemoteAnnexB.Parsed()

        init(_ bytes: [UInt8], codec: RemoteVideoCodec) {
            var codes: [Int] = []
            for index in bytes.indices.dropLast(2) where bytes[index...].starts(with: [0, 0, 1]) {
                codes.append(index)
            }
            for (index, code) in codes.enumerated() {
                let isLast = index + 1 == codes.count
                var end = isLast ? bytes.count : codes[index + 1]
                while !isLast, end > code + 3, bytes[end - 1] == 0 { end -= 1 }
                if end > code + 3 { ranges.append((code + 3)..<end) }
            }
            var sets: [Int: [UInt8]] = [:]
            for range in ranges {
                let header = bytes[range.lowerBound]
                let type = codec == .h264 ? Int(header & 0x1F) : Int((header >> 1) & 0x3F)
                let (vps, sps, pps, delimiter) = codec == .h264 ? (-1, 7, 8, 9) : (32, 33, 34, 35)
                if [vps, sps, pps].contains(type) {
                    sets[type] = Array(bytes[range])
                    continue
                }
                guard type != delimiter else { continue }
                let isSlice = codec == .h264 ? (1...5).contains(type) : type <= 31
                let isRandomAccess = codec == .h264 ? type == 5 : (16...21).contains(type)
                if isSlice { parsed.sliceCount += 1 }
                if isRandomAccess { parsed.isRandomAccess = true }
                let length = UInt32(range.count)
                parsed.lengthPrefixed += [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
                parsed.lengthPrefixed += bytes[range]
            }
            let wanted = codec == .h264 ? [7, 8] : [32, 33, 34]
            let found = wanted.compactMap { sets[$0] }
            if found.count == wanted.count { parsed.parameterSets = found }
        }
    }

    // MARK: - Core Media

    /// Parameter sets and NAL bytes from a parse, mutated, through the format and the sample buffer.
    static func formats(_ rng: inout FuzzRNG) {
        let codec: RemoteVideoCodec = rng.bool() ? .h264 : .hevc
        let parsed = RemoteAnnexB().parse(validAccessUnit(codec: codec, &rng), codec: codec)
        let mutator = FuzzMutator(dictionary: dictionary, maximumEdits: 3, maximumCount: 4_096)
        var sets = parsed.parameterSets
        if sets.isEmpty || rng.oneIn(4) {
            sets = (0..<(codec == .h264 ? 2 : 3)).map { _ in rng.bytes(count: 1 + rng.below(40)) }
        }
        sets = sets.map { rng.oneIn(3) ? $0 : [UInt8](mutator.mutate(Data($0), using: &rng)) }
        if rng.oneIn(8) { sets.append(rng.bytes(count: rng.below(16))) }
        guard let format = RemoteVideoFormat.formatDescription(codec: codec, parameterSets: sets) else { return }
        let nal = rng.oneIn(2) ? parsed.lengthPrefixed : [UInt8](mutator.mutate(Data(parsed.lengthPrefixed), using: &rng))
        _ = RemoteVideoFormat.sampleBuffer(lengthPrefixed: nal, format: format)
    }

    // MARK: - Stream splitter

    static func splitter(_ rng: inout FuzzRNG) throws {
        let input = carrierBytes(&rng)
        let expected = CarrierModel(input).controlEnds
        var splitter = RemoteRdStreamSplitter()
        var joined: [UInt8] = []
        var ends: [Int] = []
        var at = 0
        while at < input.count {
            let count = rng.oneIn(4) ? input.count - at : 1 + rng.below(min(input.count - at, 300))
            let chunkEnd = at + count
            for segment in splitter.split(Data(input[at..<chunkEnd])) {
                try FuzzRun.check(!segment.bytes.isEmpty, "an empty segment; \(describe(input))")
                joined += segment.bytes
                if segment.endsControlFrame {
                    ends.append(joined.count)
                } else {
                    try FuzzRun.check(joined.count == chunkEnd, "a piece that is not a control frame's end stops mid-chunk")
                }
            }
            try FuzzRun.check(joined.count == chunkEnd, "the pieces of a chunk are not the chunk")
            at = chunkEnd
        }
        try FuzzRun.check(joined == input, "the pieces are not the input")
        try FuzzRun.check(ends == expected, "cut after \(ends) but control frames end at \(expected); \(describe(input))")
    }

    /// Stream frames (`u8 type, u32 len` little endian, payload) of types 1-3, random bytes, or those mutated.
    static func carrierBytes(_ rng: inout FuzzRNG) -> [UInt8] {
        func frames(_ rng: inout FuzzRNG) -> [UInt8] {
            var out: [UInt8] = []
            for _ in 0..<(1 + rng.below(10)) {
                let length = rng.below(rng.oneIn(8) ? 2_000 : 40)
                out.append(UInt8(1 + rng.below(3)))
                withUnsafeBytes(of: UInt32(length).littleEndian) { out.append(contentsOf: $0) }
                out += rng.bytes(count: length)
            }
            return out
        }
        switch rng.below(4) {
        case 0: return rng.bytes(count: rng.below(300))
        case 1: return frames(&rng)
        default:
            let mutator = FuzzMutator(dictionary: dictionary, maximumEdits: 4, maximumCount: 1 << 14)
            return [UInt8](mutator.mutate(Data(frames(&rng)), using: &rng))
        }
    }

    /// Where control frames end in a whole carrier stream: frames follow each other from byte 0, and a
    /// type-1 frame whose last payload byte is in the input ends there.
    nonisolated struct CarrierModel {
        var controlEnds: [Int] = []

        init(_ bytes: [UInt8]) {
            var at = 0
            while bytes.count - at >= 5 {
                let length = (1...4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * ($1 - 1)) }
                let end = at + 5 + length
                guard end <= bytes.count else { return }
                if bytes[at] == 1 { controlEnds.append(end) }
                at = end
            }
        }
    }

    static func describe(_ bytes: [UInt8]) -> String {
        let shown = bytes.prefix(256).map { String(format: "%02x", $0) }.joined()
        return "\(bytes.count) bytes: \(shown)\(bytes.count > 256 ? "..." : "")"
    }
}
