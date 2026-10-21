import Foundation

/// H.264 Annex-B access units (what the Mac's VideoToolbox encoder emits)
/// split into NAL units, and the AVCC form VideoToolbox decodes.
public struct AnnexBAccessUnit: Sendable, Equatable {
    public var sps: Data?
    public var pps: Data?
    /// Slice and SEI NAL units, in order (no SPS, PPS or delimiters).
    public var units: [Data]
    public var isIDR: Bool

    public init(_ bytes: Data) {
        var sps: Data?
        var pps: Data?
        var units: [Data] = []
        var idr = false
        for nal in Self.split(bytes) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            case 9, 10, 11, 12: continue // delimiter, end of sequence or stream, filler
            case 5:
                idr = true
                units.append(nal)
            default: units.append(nal)
            }
        }
        self.sps = sps
        self.pps = pps
        self.units = units
        isIDR = idr
    }

    /// NAL units between 3- or 4-byte start codes.
    public static func split(_ bytes: Data) -> [Data] {
        let b = [UInt8](bytes)
        var starts: [(at: Int, code: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append((i, 3))
                    i += 3
                    continue
                }
                if i + 3 < b.count, b[i + 2] == 0, b[i + 3] == 1 {
                    starts.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var out: [Data] = []
        for (n, start) in starts.enumerated() {
            let begin = start.at + start.code
            let end = n + 1 < starts.count ? starts[n + 1].at : b.count
            if end > begin { out.append(Data(b[begin..<end])) }
        }
        return out
    }

    /// The slices as one AVCC buffer: each unit with a 4-byte big-endian length.
    public var avcc: Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}
