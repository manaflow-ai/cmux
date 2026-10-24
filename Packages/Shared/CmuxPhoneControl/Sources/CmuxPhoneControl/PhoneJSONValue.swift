import Foundation

/// A deliberately small JSON value type used by the line protocol.
/// Keeping the wire representation explicit avoids `Any` crossing actor
/// boundaries and makes unknown fields safe to ignore.
public enum PhoneJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([PhoneJSONValue])
    case object([String: PhoneJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PhoneJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PhoneJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public init<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    public subscript(key: String) -> PhoneJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }
}
