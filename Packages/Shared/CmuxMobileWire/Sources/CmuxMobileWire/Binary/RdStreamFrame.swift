public import Foundation

/// browser and rd channels: one cmux.rd/1 stream frame without its u32
/// length (the record already has one). cmux.rb/1 rides as rd control.
public struct RdStreamFrame: Hashable, Sendable {
    public var type: RdStreamType
    public var data: Data

    public init(type: RdStreamType, data: Data) {
        self.type = type
        self.data = data
    }

    public init(decoding payload: Data) throws(RecordError) {
        guard let first = payload.first, let type = RdStreamType(rawValue: first) else {
            throw RecordError(.truncated, "unknown rd stream frame type")
        }
        self.init(type: type, data: payload.tail(from: 1))
    }

    public var encoded: Data {
        var out = Data([type.rawValue])
        out.append(data)
        return out
    }
}
