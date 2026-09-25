import Foundation

/// A dynamically-shaped JSON value decoded from one transcript JSONL line.
///
/// Transcript lines have loose, evolving schemas, so the parsers walk a
/// typed JSON tree instead of decoding fixed `Codable` shapes. Unknown or
/// missing keys read as `nil` and the parsers fail open (skip the line).
enum TranscriptJSONValue: Sendable, Equatable, Codable {
    /// A JSON string.
    case string(String)
    /// A JSON number (integers are represented as their double value).
    case number(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON object.
    case object([String: TranscriptJSONValue])
    /// A JSON array.
    case array([TranscriptJSONValue])
    /// JSON null.
    case null

    /// Decodes one JSONL line, returning `nil` for malformed JSON.
    ///
    /// - Parameter jsonLine: The raw line text.
    init?(jsonLine: String) {
        let data = Data(jsonLine.utf8)
        guard let value = try? JSONDecoder().decode(TranscriptJSONValue.self, from: data) else {
            return nil
        }
        self = value
    }

    /// Creates a value by trying each JSON shape in turn.
    ///
    /// - Parameter decoder: The decoder to read from.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: TranscriptJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([TranscriptJSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    /// Encodes the value back to its JSON shape.
    ///
    /// - Parameter encoder: The encoder to write to.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The string payload, or `nil` when this is not a string.
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The boolean payload, or `nil` when this is not a boolean.
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The numeric payload, or `nil` when this is not a number.
    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The numeric payload as an integer, or `nil` when not a number.
    var int: Int? {
        guard let double else { return nil }
        return Int(double)
    }

    /// The object payload, or `nil` when this is not an object.
    var object: [String: TranscriptJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The array payload, or `nil` when this is not an array.
    var array: [TranscriptJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Looks up a key on an object value; `nil` for other shapes.
    ///
    /// - Parameter key: The object key to read.
    subscript(key: String) -> TranscriptJSONValue? {
        object?[key]
    }

    /// Renders the value as compact JSON with sorted keys.
    ///
    /// - Returns: The compact JSON text, or an empty string on failure.
    func compactJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
