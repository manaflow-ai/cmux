import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
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

    var string: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    func textFragments() -> [String] {
        switch self {
        case .string(let value):
            [value]
        case .array(let values):
            values.flatMap { $0.textFragments() }
        case .object(let object):
            if let text = object["text"]?.string {
                [text]
            } else if let content = object["content"] {
                content.textFragments()
            } else {
                []
            }
        default:
            []
        }
    }
}
