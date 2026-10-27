public import Foundation

/// Annex-B parsing for H.264 and HEVC access units: splits on start codes,
/// pulls out the parameter sets (VPS/SPS/PPS) for the format description,
/// and rewrites the remaining NAL units with 4-byte big-endian lengths
/// (the form VideoToolbox decodes).
public nonisolated struct RemoteAnnexB {
    public nonisolated init() {}
    public nonisolated struct Parsed: Sendable, Equatable {
        /// H.264: [SPS, PPS]. HEVC: [VPS, SPS, PPS]. Empty when the access
        /// unit carries none (every non-key frame).
        public var parameterSets: [[UInt8]] = []
        /// Every other NAL unit (access unit delimiters dropped), each
        /// prefixed with its 4-byte big-endian length.
        public var lengthPrefixed: [UInt8] = []
        /// An IDR (H.264) or IRAP picture (HEVC: BLA, IDR, CRA).
        public var isRandomAccess = false
        /// Coded slice NAL units.
        public var sliceCount = 0
    }

    /// Ranges of the NAL units in `bytes`, start codes removed. Accepts 3- and
    /// 4-byte start codes; trailing zero bytes before a start code belong to
    /// the start code.
    ///
    /// One pass over the bytes with the length of the zero run before each:
    /// a `01` after two or more zeros is a start code, and the unit before it
    /// ends where that run began. Nothing is indexed, so no input can read
    /// past the bytes (p10-stability-093).
    public nonisolated func nalRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var unitStart: Int?
        var zeros = 0
        for (position, byte) in bytes.enumerated() {
            guard byte == 1, zeros >= 2 else {
                zeros = byte == 0 ? zeros + 1 : 0
                continue
            }
            // The run began after the unit's start (it was reset there), so the range is not reversed.
            if let start = unitStart, position - zeros > start { ranges.append(start..<(position - zeros)) }
            unitStart = position + 1
            zeros = 0
        }
        if let start = unitStart, bytes.count > start { ranges.append(start..<bytes.count) }
        return ranges
    }

    public nonisolated func parse(_ data: Data, codec: RemoteVideoCodec) -> Parsed {
        parse([UInt8](data), codec: codec)
    }

    public nonisolated func parse(_ bytes: [UInt8], codec: RemoteVideoCodec) -> Parsed {
        var parsed = Parsed()
        parsed.lengthPrefixed.reserveCapacity(bytes.count + 16)
        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        for range in nalRanges(bytes) {
            let unit = bytes.dropFirst(range.lowerBound).prefix(range.count)
            guard let header = unit.first else { continue }
            switch NALType(header: header, codec: codec) {
            case .vps: vps = Array(unit)
            case .sps: sps = Array(unit)
            case .pps: pps = Array(unit)
            case .delimiter: continue
            case let .other(isSlice, isRandomAccess):
                if isSlice { parsed.sliceCount += 1 }
                if isRandomAccess { parsed.isRandomAccess = true }
                appendLengthPrefixed(unit, to: &parsed.lengthPrefixed)
            }
        }
        switch codec {
        case .h264:
            if let sps, let pps { parsed.parameterSets = [sps, pps] }
        case .hevc:
            if let vps, let sps, let pps { parsed.parameterSets = [vps, sps, pps] }
        }
        return parsed
    }

    private nonisolated func appendLengthPrefixed(_ nal: ArraySlice<UInt8>, to out: inout [UInt8]) {
        // decode-trap-allow: a unit is one rd frame, at most MAX_FRAME_SHARDS (4096) datagrams of at most 1332 bytes
        // (cmux-rd-proto), so its length fits a u32 by construction, not by checking the peer's bytes.
        let length = UInt32(nal.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(contentsOf: nal)
    }

    nonisolated enum NALType: Equatable {
        case vps, sps, pps, delimiter
        case other(isSlice: Bool, isRandomAccess: Bool)

        nonisolated init(header: UInt8, codec: RemoteVideoCodec) {
            switch codec {
            case .h264:
                let type = header & 0x1F
                switch type {
                case 7: self = .sps
                case 8: self = .pps
                case 9: self = .delimiter
                default: self = .other(isSlice: (1...5).contains(type), isRandomAccess: type == 5)
                }
            case .hevc:
                let type = (header >> 1) & 0x3F
                switch type {
                case 32: self = .vps
                case 33: self = .sps
                case 34: self = .pps
                case 35: self = .delimiter
                default: self = .other(isSlice: type <= 31, isRandomAccess: (16...21).contains(type))
                }
            }
        }
    }
}
