public import Foundation

/// Annex-B parsing for H.264 and HEVC access units: splits on start codes,
/// pulls out the parameter sets (VPS/SPS/PPS) for the format description,
/// and rewrites the remaining NAL units with 4-byte big-endian lengths
/// (the form VideoToolbox decodes).
public struct RemoteAnnexB {
    public nonisolated init() {}
    public struct Parsed: Sendable, Equatable {
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
    public nonisolated func nalRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        let n = bytes.count
        while i + 3 <= n {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, i + 3))
                    i += 3
                    continue
                }
                if i + 4 <= n, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var ranges: [Range<Int>] = []
        for (index, start) in starts.enumerated() {
            let isLast = index + 1 == starts.count
            var end = isLast ? n : starts[index + 1].code
            while !isLast, end > start.nal, bytes[end - 1] == 0 { end -= 1 }
            if end > start.nal { ranges.append(start.nal..<end) }
        }
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
            let nal = NALType(header: bytes[range.lowerBound], codec: codec)
            switch nal {
            case .vps: vps = Array(bytes[range])
            case .sps: sps = Array(bytes[range])
            case .pps: pps = Array(bytes[range])
            case .delimiter: continue
            case let .other(isSlice, isRandomAccess):
                if isSlice { parsed.sliceCount += 1 }
                if isRandomAccess { parsed.isRandomAccess = true }
                appendLengthPrefixed(bytes[range], to: &parsed.lengthPrefixed)
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
        let length = UInt32(nal.count)
        out.append(UInt8(length >> 24))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
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
