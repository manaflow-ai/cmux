import Foundation

/// Bounds-checked reader for one small Iroh stream-header payload. Reads go
/// front to back over the bytes not read yet, so no read computes an index;
/// a read past the end throws ``CmxIrohStreamHeaderCodecError/invalidPayload``.
struct CmxIrohBinaryCursor {
    private var rest: Data

    init(data: Data) {
        rest = data
    }

    var remainingByteCount: Int {
        rest.count
    }

    mutating func readUInt8() throws -> UInt8 {
        try readBigEndian()
    }

    mutating func readUInt16() throws -> UInt16 {
        try readBigEndian()
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBigEndian()
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBigEndian()
    }

    /// A big-endian length field as a byte count.
    mutating func readByteCount<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> Int {
        guard let count = Int(exactly: try readBigEndian() as T) else {
            throw CmxIrohStreamHeaderCodecError.invalidPayload
        }
        return count
    }

    mutating func readData(byteCount: Int) throws -> Data {
        guard byteCount >= 0, byteCount <= rest.count else {
            throw CmxIrohStreamHeaderCodecError.invalidPayload
        }
        let field = rest.prefix(byteCount)
        rest = rest.dropFirst(byteCount)
        return field
    }

    mutating func readString(byteCount: Int) throws -> String {
        let bytes = try readData(byteCount: byteCount)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw CmxIrohStreamHeaderCodecError.invalidPayload
        }
        return value
    }

    private mutating func readBigEndian<T: FixedWidthInteger & UnsignedInteger>() throws -> T {
        let bytes = try readData(byteCount: MemoryLayout<T>.size)
        // Every unsigned fixed-width type holds a whole byte: the widening T(byte) cannot trap.
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
