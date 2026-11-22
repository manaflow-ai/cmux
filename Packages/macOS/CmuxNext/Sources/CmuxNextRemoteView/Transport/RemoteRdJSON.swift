import Foundation

/// Any JSON value, kept as parsed so a service's message body passes through
/// rd untouched (rd change B3.2). Numbers stay `Double` unless they are
/// integers, so integers round-trip exactly.
public nonisolated indirect enum RemoteRdJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([RemoteRdJSON])
    case object([String: RemoteRdJSON])
}

nonisolated extension RemoteRdJSON: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        if let object = try? decoder.container(keyedBy: Key.self) {
            var out: [String: RemoteRdJSON] = [:]
            for key in object.allKeys {
                out[key.stringValue] = try object.decode(RemoteRdJSON.self, forKey: key)
            }
            self = .object(out)
            return
        }
        if var array = try? decoder.unkeyedContainer() {
            var out: [RemoteRdJSON] = []
            while !array.isAtEnd {
                out.append(try array.decode(RemoteRdJSON.self))
            }
            self = .array(out)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? single.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .object(object):
            var c = encoder.container(keyedBy: Key.self)
            for (key, value) in object {
                try c.encode(value, forKey: Key(stringValue: key))
            }
        case let .array(array):
            var c = encoder.unkeyedContainer()
            for value in array {
                try c.encode(value)
            }
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case let .bool(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .int(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .double(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .string(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }
}
