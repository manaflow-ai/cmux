import Foundation

/// Cuts an H.264 Annex B byte stream (start codes `00 00 01` or
/// `00 00 00 01`) into NAL units, across pipe chunks that split anywhere.
/// A unit is complete only when the next start code arrives.
struct AnnexBParser {
    private var buffer = Data()
    /// Where the current unit's payload starts in `buffer`; nil before the first start code.
    private var unitStart: Int?
    /// How far `buffer` has been scanned for start codes.
    private var scanned = 0

    /// Appends `chunk` and returns the units it completed, in order.
    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var units: [Data] = []
        let bytes = [UInt8](buffer)
        var i = max(scanned, 0)
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let start = unitStart {
                    var end = i
                    // A 4-byte start code's leading zero (and trailing_zero_8bits) belong to no unit.
                    while end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                unitStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        scanned = i
        // Drop consumed bytes so the buffer holds only the unit in progress.
        if let start = unitStart, start > 0 {
            buffer = Data(bytes[start...])
            scanned -= start
            unitStart = 0
        }
        return units
    }

    /// The unit in progress (at the end of the stream).
    mutating func flush() -> Data? {
        defer { buffer = Data(); unitStart = nil; scanned = 0 }
        guard let start = unitStart, start < buffer.count else { return nil }
        let bytes = [UInt8](buffer)
        var end = bytes.count
        while end > start, bytes[end - 1] == 0 { end -= 1 }
        return end > start ? Data(bytes[start..<end]) : nil
    }
}
