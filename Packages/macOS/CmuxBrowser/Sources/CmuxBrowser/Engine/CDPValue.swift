import Foundation

/// JSON values used by the Chrome DevTools Protocol wire format.
public enum CDPValue: Codable, Equatable, Sendable {
    /// JSON null.
    case null
    /// A JSON Boolean.
    case bool(Bool)
    /// A JSON number represented as a double.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([CDPValue])
    /// A JSON object.
    case object([String: CDPValue])

    /// Decodes one recursively typed JSON value.
    ///
    /// - Parameter decoder: Decoder positioned at one JSON value.
    /// - Throws: An error when the payload is not a valid JSON value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CDPValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CDPValue].self))
        }
    }

    /// Encodes this value using its native JSON representation.
    ///
    /// - Parameter encoder: Encoder that receives this value.
    /// - Throws: An error when the encoder cannot represent the value.
    public func encode(to encoder: any Encoder) throws {
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

    /// Converts a Foundation JSON-compatible value into a typed CDP value.
    ///
    /// - Parameter value: Foundation value, collection, or `nil`.
    public init(any value: Any?) {
        guard let value else {
            self = .null
            return
        }
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(CDPValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(CDPValue.init(any:)))
        default:
            self = .string(String(describing: value))
        }
    }

    /// Foundation representation suitable for existing socket payload code.
    public var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let value):
            return value.map(\.anyValue)
        case .object(let value):
            return value.mapValues(\.anyValue)
        }
    }

    /// Reads one member when this value is an object.
    ///
    /// - Parameter key: Object member name.
    /// - Returns: The member value, or `nil` when this is not an object or the key is absent.
    public subscript(key: String) -> CDPValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }

    /// Associated string, or `nil` for another JSON kind.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Associated number, or `nil` for another JSON kind.
    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}
