import Foundation

/// Little-endian writer for `LinkFrame`.
struct ByteWriter {
    private(set) var data = Data()

    init(capacity: Int = 32) {
        data.reserveCapacity(capacity)
    }

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) { append(value.littleEndian) }

    mutating func u32(_ value: UInt32) { append(value.littleEndian) }

    mutating func u64(_ value: UInt64) { append(value.littleEndian) }

    mutating func bytes(_ value: Data) { data.append(value) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}
