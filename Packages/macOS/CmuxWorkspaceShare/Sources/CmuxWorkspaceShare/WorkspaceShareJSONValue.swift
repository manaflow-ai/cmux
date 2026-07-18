import Foundation

/// A sendable JSON value used by the versioned workspace-share protocol.
public enum WorkspaceShareJSONValue: Codable, Equatable, Sendable {
    /// A JSON string.
    case string(String)
    /// A signed JSON integer.
    case integer(Int64)
    /// An unsigned JSON integer.
    case unsigned(UInt64)
    /// A non-integral JSON number.
    case number(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON object.
    case object([String: WorkspaceShareJSONValue])
    /// A JSON array.
    case array([WorkspaceShareJSONValue])
    /// The JSON `null` value.
    case null

    /// Decodes one JSON value.
    /// - Parameter decoder: Decoder positioned at the JSON value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    /// Encodes one JSON value.
    /// - Parameter encoder: Encoder receiving the JSON value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsigned(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Converts an encodable DTO into a JSON value without an untyped dictionary.
    /// - Parameter value: DTO to encode.
    /// - Returns: The equivalent JSON value.
    public static func encode<T: Encodable & Sendable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    /// Decodes a DTO from this JSON value.
    /// - Parameter type: DTO type to decode.
    /// - Returns: The decoded value.
    public func decode<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    /// Returns the object payload, or `nil` for another JSON kind.
    public var objectValue: [String: Self]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    /// Returns the string payload, or `nil` for another JSON kind.
    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
