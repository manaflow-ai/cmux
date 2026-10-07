import Foundation

extension Data {
    /// Reads `count` little-endian bytes at `offset` from the start of the data.
    func littleEndian(at offset: Int, count: Int) -> UInt64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for i in 0..<count {
            value |= UInt64(self[base + i]) << (8 * UInt64(i))
        }
        return value
    }

    mutating func appendLittleEndian(_ value: UInt64, count: Int) {
        for i in 0..<count {
            append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))))
        }
    }

    /// The bytes from `offset` to the end, re-based at index 0.
    func tail(from offset: Int) -> Data {
        Data(self[(startIndex + offset)...])
    }
}
