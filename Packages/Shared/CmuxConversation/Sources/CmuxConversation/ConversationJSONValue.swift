public import Foundation

/// A lossless JSON value used to retain provider payloads that have no typed mapping yet.
public enum ConversationJSONValue: Codable, Hashable, Sendable {
    /// JSON null.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON number represented as a string to avoid precision loss.
    case number(String)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([ConversationJSONValue])
    /// A JSON object.
    case object([String: ConversationJSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let value = try? c.decode(Bool.self) { self = .bool(value); return }
        if let value = try? c.decode(Int64.self) { self = .number(String(value)); return }
        if let value = try? c.decode(UInt64.self) { self = .number(String(value)); return }
        if let value = try? c.decode(Decimal.self) { self = .number(String(describing: value)); return }
        if let value = try? c.decode(String.self) { self = .string(value); return }
        if let value = try? c.decode([ConversationJSONValue].self) { self = .array(value); return }
        self = .object(try c.decode([String: ConversationJSONValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value):
            if let integer = Int64(value) { try c.encode(integer) }
            else if let integer = UInt64(value) { try c.encode(integer) }
            else if value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                    let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) {
                try c.encode(decimal)
            } else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Invalid JSON number"))
            }
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}
