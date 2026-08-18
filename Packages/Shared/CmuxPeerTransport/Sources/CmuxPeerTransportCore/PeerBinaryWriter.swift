import Foundation

/// Append-only big-endian writer for one small binary frame.
struct PeerBinaryWriter {
    private(set) var data: Data

    init(capacity: Int = 64) {
        self.data = Data(capacity: capacity)
    }

    mutating func append(_ byte: UInt8) {
        data.append(byte)
    }

    mutating func append(_ value: UInt16) {
        appendBigEndian(value)
    }

    mutating func append(_ value: UInt32) {
        appendBigEndian(value)
    }

    mutating func append(_ value: UInt64) {
        appendBigEndian(value)
    }

    mutating func append(contentsOf bytes: Data) {
        data.append(bytes)
    }

    private mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
