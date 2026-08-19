import Foundation

/// Bounds-checked big-endian reader for one small binary frame.
struct PeerBinaryCursor {
    /// Raised on reads past the end of the frame or non-UTF-8 string bytes.
    ///
    /// This type is internal, so codecs must map it to their own public
    /// payload error at the frame boundary instead of letting it escape.
    enum Failure: Error, Equatable, Sendable {
        case insufficientBytes
        case invalidUTF8
    }

    private let data: Data
    private(set) var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try readData(byteCount: 1)
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(byteCount: 2)
        return bytes.reduce(UInt16.zero) { partial, byte in
            (partial << 8) | UInt16(byte)
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(byteCount: 4)
        return bytes.reduce(UInt32.zero) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(byteCount: 8)
        return bytes.reduce(UInt64.zero) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    mutating func readData(byteCount: Int) throws -> Data {
        guard byteCount >= 0, byteCount <= remainingByteCount else {
            throw Failure.insufficientBytes
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: byteCount)
        offset += byteCount
        return data[start ..< end]
    }

    mutating func readString(byteCount: Int) throws -> String {
        let bytes = try readData(byteCount: byteCount)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw Failure.invalidUTF8
        }
        return value
    }
}
