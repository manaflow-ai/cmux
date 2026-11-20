public import Foundation

/// A JSON value: the harness payloads (`rawInput`, `answers`) this package
/// reads and writes have no fixed Swift type.
public enum AgentQuestionJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentQuestionJSON])
    case object([String: AgentQuestionJSON])

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
        } else if let value = try? container.decode([AgentQuestionJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AgentQuestionJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Decodes UTF-8 JSON text.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(AgentQuestionJSON.self, from: data)
    }

    /// Compact JSON with sorted keys, so equal values encode to equal bytes.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public subscript(key: String) -> AgentQuestionJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Follows a `/`-separated path of object keys.
    public func at(_ path: String) -> AgentQuestionJSON? {
        path.split(separator: "/").reduce(Optional(self)) { value, key in value?[String(key)] }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A non-empty string after trimming whitespace.
    public var text: String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [AgentQuestionJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: AgentQuestionJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension AgentQuestionJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: AgentQuestionJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AgentQuestionJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
