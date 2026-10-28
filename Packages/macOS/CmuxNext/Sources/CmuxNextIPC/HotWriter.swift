// The writer half of the hot-message codec (HotLayout.swift).

/// Appends values to a payload, little endian.
public struct HotWriter: Sendable {
    public private(set) var bytes: [UInt8]

    init(layoutVersion: UInt8) {
        bytes = [layoutVersion]
    }

    public mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    /// The byte before an optional or nullable field: 1 when a value follows.
    public mutating func tag(_ present: Bool) {
        bytes.append(present ? 1 : 0)
    }

    public mutating func enumeration(_ index: UInt8) {
        bytes.append(index)
    }

    public mutating func u16(_ value: UInt16) { append(value) }
    public mutating func u32(_ value: UInt32) { append(value) }
    public mutating func u64(_ value: UInt64) { append(value) }
    public mutating func i32(_ value: Int32) { append(UInt32(bitPattern: value)) }
    public mutating func i64(_ value: Int64) { append(UInt64(bitPattern: value)) }
    public mutating func f32(_ value: Float) { append(value.bitPattern) }
    public mutating func f64(_ value: Double) { append(value.bitPattern) }

    /// A u16 byte length, then the UTF-8.
    public mutating func string(_ value: String, max: UInt16) throws(HotEncodeError) {
        let length = value.utf8.count
        guard length <= Int(max) else { throw .stringTooLong(length: length, max: max) }
        u16(UInt16(truncatingIfNeeded: length))
        bytes.append(contentsOf: value.utf8)
    }

    /// The u16 count before an array's items.
    public mutating func count(_ count: Int, max: UInt16) throws(HotEncodeError) {
        guard count <= Int(max) else { throw .arrayTooLong(length: count, max: max) }
        u16(UInt16(truncatingIfNeeded: count))
    }

    private mutating func append<Value: FixedWidthInteger & UnsignedInteger>(_ value: Value) {
        for shift in stride(from: 0, to: Value.bitWidth, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
