import Foundation

enum JSONValue: Encodable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case integer(Int)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
