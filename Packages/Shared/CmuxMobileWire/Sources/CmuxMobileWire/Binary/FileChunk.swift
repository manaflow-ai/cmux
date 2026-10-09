public import Foundation

/// files.* channels: `u64 offset` + bytes.
public struct FileChunk: Hashable, Sendable {
    public var offset: UInt64
    public var data: Data

    public init(offset: UInt64, data: Data) {
        self.offset = offset
        self.data = data
    }

    public init(decoding payload: Data) throws(RecordError) {
        guard payload.count >= 8 else { throw RecordError(.truncated, "file chunk without its offset") }
        self.init(offset: payload.littleEndian(at: 0, count: 8), data: payload.tail(from: 8))
    }

    public var encoded: Data {
        var out = Data(capacity: 8 + data.count)
        out.appendLittleEndian(offset, count: 8)
        out.append(data)
        return out
    }
}
