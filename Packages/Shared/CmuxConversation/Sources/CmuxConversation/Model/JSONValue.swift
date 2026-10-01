/// A JSON value, for backend-specific payloads the GUI model carries but
/// does not interpret (``ExtensionItem``).
public enum JSONValue: Hashable, Sendable, Codable {
    /// JSON `null`.
    case null
    /// A boolean.
    case bool(Bool)
    /// A number.
    case number(Double)
    /// A string.
    case string(String)
    /// An array.
    case array([JSONValue])
    /// An object.
    case object([String: JSONValue])

    /// Decodes any JSON value.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the input is not JSON.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    /// Encodes the value as JSON.
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: `EncodingError` from the encoder.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    /// The member named `key` when this is an object.
    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    /// The string value, when this is a string.
    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// The numeric value as `UInt64`, when this is a non-negative number.
    public var uint64Value: UInt64? {
        if case let .number(n) = self, n >= 0 { return UInt64(n) }
        return nil
    }

    /// The boolean value, when this is a boolean.
    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// The elements, when this is an array.
    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }
}
