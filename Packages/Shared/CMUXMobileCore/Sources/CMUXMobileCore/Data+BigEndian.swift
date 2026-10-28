import Foundation

extension Data {
    /// Appends `value` most significant byte first: the writing half of
    /// ``WireByteReader/bigEndian(_:)``, with no pointer to the value's storage.
    mutating func appendBigEndian<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
