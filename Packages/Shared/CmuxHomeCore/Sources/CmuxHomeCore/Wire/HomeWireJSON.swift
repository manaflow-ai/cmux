public import Foundation

/// A JSON value as the hosted `cmux.wire/1` owners send it: frames, op
/// replies and read values. `WireHomeSource` decodes every body into this
/// first and reads the fields it knows, so an owner field this build does not
/// know never fails a frame.
public enum HomeWireJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HomeWireJSON])
    case object([String: HomeWireJSON])

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
        } else if let value = try? container.decode([HomeWireJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: HomeWireJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integers go out without a fraction (seqs, part indexes, limits).
            if value.rounded() == value, abs(value) < 9e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses one body or frame; nil when it is not JSON.
    public static func parse(_ data: Data) -> HomeWireJSON? {
        try? JSONDecoder().decode(HomeWireJSON.self, from: data)
    }

    /// Parses one text frame; nil when it is not JSON.
    public static func parse(_ text: String) -> HomeWireJSON? {
        parse(Data(text.utf8))
    }

    /// The compact JSON text of this value (sorted keys, so tests compare it).
    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// The JSON bytes of this value.
    public var data: Data { Data(text.utf8) }

    /// The field `key` of an object; `.null` for anything else.
    public subscript(key: String) -> HomeWireJSON {
        if case .object(let fields) = self { return fields[key] ?? .null }
        return .null
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var array: [HomeWireJSON]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: HomeWireJSON]? { if case .object(let value) = self { value } else { nil } }
    public var isNull: Bool { self == .null }

    /// A non-negative integer (a seq, a rev, a count); also one sent as a decimal string.
    public var uint: UInt64? {
        switch self {
        case .number(let value) where value >= 0 && value < 1.8e19 && value.rounded() == value: UInt64(value)
        case .string(let text): UInt64(text)
        default: nil
        }
    }

    public var int: Int? { uint.flatMap { Int(exactly: $0) } ?? double.flatMap { Int(exactly: $0) } }
}

extension HomeWireJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: HomeWireJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, HomeWireJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(nilLiteral: ()) { self = .null }

    /// A seq, rev or count as a JSON number.
    public static func uint(_ value: UInt64) -> HomeWireJSON { .number(Double(value)) }
    /// An optional string as a JSON string or null.
    public static func optional(_ value: String?) -> HomeWireJSON { value.map(HomeWireJSON.string) ?? .null }
}
