public import Foundation

/// One H.264 access unit as NAL units. Converts between the Annex-B form on
/// the wire (`00 00 00 01` start codes, parameter sets in front of every
/// keyframe) and the length-prefixed form VideoToolbox reads and writes.
public struct H264AccessUnit: Hashable, Sendable {
    /// NAL units without start codes or length prefixes.
    public var nalUnits: [Data]

    public init(nalUnits: [Data]) {
        self.nalUnits = nalUnits.filter { !$0.isEmpty }
    }

    /// Parses Annex-B bytes (3- or 4-byte start codes).
    public init(annexB data: Data) {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[s..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count { units.append(Data(bytes[s...])) }
        self.init(nalUnits: units)
    }

    /// Parses length-prefixed NAL units (AVCC, `lengthSize` 4 by default),
    /// optionally preceded by parameter sets (a keyframe's SPS and PPS).
    public init(lengthPrefixed data: Data, lengthSize: Int = 4, parameterSets: [Data] = []) throws(RdWireError) {
        let bytes = [UInt8](data)
        var units = parameterSets
        var i = 0
        while i < bytes.count {
            guard i + lengthSize <= bytes.count else { throw RdWireError("truncated NAL length") }
            var length = 0
            for k in 0..<lengthSize { length = length << 8 | Int(bytes[i + k]) }
            i += lengthSize
            guard length > 0, i + length <= bytes.count else { throw RdWireError("NAL length") }
            units.append(Data(bytes[i..<i + length]))
            i += length
        }
        self.init(nalUnits: units)
    }

    /// NAL unit type (low 5 bits of the first byte).
    public static func type(of unit: Data) -> UInt8 {
        (unit.first ?? 0) & 0x1f
    }

    public var annexB: Data {
        var out = Data()
        for unit in nalUnits {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(unit)
        }
        return out
    }

    /// The units that are not parameter sets, length-prefixed (4 bytes),
    /// for a `CMSampleBuffer`.
    public var lengthPrefixedSlices: Data {
        var out = Data()
        for unit in nalUnits where !Self.isParameterSet(unit) {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }

    public var sps: Data? { nalUnits.first { Self.type(of: $0) == 7 } }
    public var pps: Data? { nalUnits.first { Self.type(of: $0) == 8 } }

    /// Contains an IDR slice.
    public var isKeyframe: Bool { nalUnits.contains { Self.type(of: $0) == 5 } }

    private static func isParameterSet(_ unit: Data) -> Bool {
        let type = type(of: unit)
        return type == 7 || type == 8 || type == 9
    }
}
