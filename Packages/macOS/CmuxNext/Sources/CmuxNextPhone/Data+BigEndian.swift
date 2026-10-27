import Foundation

extension Data {
    /// Appends `value`'s bytes, most significant first (network order), without viewing its memory.
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        for shift in stride(from: Value.bitWidth - 8, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
