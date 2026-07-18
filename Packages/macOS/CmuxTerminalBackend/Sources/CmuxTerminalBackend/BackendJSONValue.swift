internal import Foundation

/// A bounded protocol payload uses this value only where a capability owns an
/// operation-specific schema. Core identity and revision fields stay typed.
public enum BackendJSONValue: Codable, Equatable, Sendable {
    /// A JSON `null` value.
    case null

    /// A JSON Boolean value.
    case bool(Bool)

    /// A signed integer value.
    case integer(Int64)

    /// An unsigned integer value.
    case unsignedInteger(UInt64)

    /// A floating-point number value.
    case number(Double)

    /// A string value.
    case string(String)

    /// An array of JSON values.
    case array([BackendJSONValue])

    /// An object keyed by strings.
    case object([String: BackendJSONValue])

    /// Decodes one protocol JSON value without erasing integer precision.
    ///
    /// - Parameter decoder: The decoder containing the JSON value.
    /// - Throws: A decoding error when the value has no supported JSON form.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BackendJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BackendJSONValue].self))
        }
    }

    /// Encodes the value in its corresponding JSON form.
    ///
    /// - Parameter encoder: The encoder that receives the JSON value.
    /// - Throws: An encoding error.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
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
}
