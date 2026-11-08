public import Foundation

/// A JSON value that can safely cross Swift concurrency domains.
public enum ClientConfigJSONValue: Codable, Sendable, Equatable {
    /// A JSON null value.
    case null
    /// A JSON boolean value.
    case bool(Bool)
    /// A JSON number value.
    case number(Double)
    /// A JSON string value.
    case string(String)
    /// A JSON array value.
    case array([ClientConfigJSONValue])
    /// A JSON object value.
    case object([String: ClientConfigJSONValue])

    /// Decodes a JSON value from a single-value container.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClientConfigJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ClientConfigJSONValue].self))
        }
    }

    /// Encodes this value into JSON.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
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

    /// The boolean value when this JSON value is a boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The string value when this JSON value is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The object value when this JSON value is an object.
    public var objectValue: [String: ClientConfigJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Re-decodes this JSON value into a concrete Decodable type.
    public func decode<Value: Decodable>(
        _ type: Value.Type = Value.self,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(Value.self, from: data)
    }
}
