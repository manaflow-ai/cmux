import Foundation

/// One JSON document node. The wire is JSON everywhere (contract 6.2, decision D5),
/// so every frame payload field is one of these.
public enum JSONValue: Sendable, Equatable {
    /// JSON null.
    case null
    /// A JSON Boolean.
    case bool(Bool)
    /// An exactly represented signed 64-bit integer.
    case int(Int64)
    /// A JSON number not represented by the integer case during decoding.
    case double(Double)
    /// A Unicode JSON string, including base64-encoded binary payloads.
    case string(String)
    /// An ordered sequence of JSON values.
    case array([JSONValue])
    /// A JSON object indexed by field name.
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    /// Decodes a JSON node, preferring exact integer representation for numbers.
    ///
    /// - Parameter decoder: Decoder positioned at one JSON value.
    /// - Throws: A decoding error if the value has no supported representation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    /// Encodes the associated value using its native JSON representation.
    ///
    /// - Parameter encoder: Encoder receiving this node.
    /// - Throws: The encoder's error, including unsupported nonfinite numbers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Binary payloads ride as base64 strings (contract 6.2).
    /// - Parameter data: Bytes to encode without loss.
    /// - Returns: A base64 string node.
    public static func data(_ data: Data) -> JSONValue { .string(data.base64EncodedString()) }

    /// Decoded bytes for a valid base64 string node, otherwise nil.
    public var dataValue: Data? {
        guard case .string(let string) = self else { return nil }
        return Data(base64Encoded: string)
    }

    /// Associated string, or nil for a non-string node.
    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    /// Exact signed integer value, or nil for fractional, out-of-range, or nonnumeric nodes.
    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    /// Associated Boolean, or nil for a non-Boolean node.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// Associated field dictionary, or nil for a non-object node.
    public var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    /// Associated ordered elements, or nil for a non-array node.
    public var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }
}
