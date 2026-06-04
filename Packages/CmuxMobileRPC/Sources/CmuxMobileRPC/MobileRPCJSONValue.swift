internal import Foundation

/// A lossless, typed JSON document model.
///
/// ``MobileCoreRPCClient`` rewrites already-encoded request envelopes in two
/// places (guaranteeing an `id`, injecting the `auth` object). This enum lets
/// those rewrites decode → mutate → re-encode through `Codable` instead of
/// `JSONSerialization`'s untyped `[String: Any]`, while preserving every value
/// in the original document (unknown keys included).
enum MobileRPCJSONValue: Sendable, Equatable, Codable {
    /// JSON `null`.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON number with no fractional part.
    case int(Int64)
    /// A JSON number with a fractional part (or beyond `Int64` range).
    case double(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([MobileRPCJSONValue])
    /// A JSON object.
    case object([String: MobileRPCJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: MobileRPCJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([MobileRPCJSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// The wrapped string when this value is `.string`, else `nil`.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped object when this value is `.object`, else `nil`.
    var objectValue: [String: MobileRPCJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
