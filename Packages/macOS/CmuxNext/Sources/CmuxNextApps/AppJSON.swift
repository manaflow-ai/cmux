public import Foundation

/// A JSON value: manifest documents, scene props, operation params and
/// results. Numbers keep their Double form; integers round-trip exactly up
/// to 2^53, which covers every id and count the app platform carries.
public nonisolated enum AppJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AppJSON])
    case object([String: AppJSON])

    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
    public var arrayValue: [AppJSON]? { if case .array(let v) = self { v } else { nil } }
    public var objectValue: [String: AppJSON]? { if case .object(let v) = self { v } else { nil } }
    public var isNull: Bool { self == .null }

    public subscript(_ key: String) -> AppJSON? { objectValue?[key] }

    /// The JSON type name the validator reports (`string`, `object`, ...).
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number(let v): v.rounded() == v ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Parses UTF-8 JSON (any top-level value).
    public static func parse(_ data: Data) throws -> AppJSON {
        try AppJSON(foundation: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public static func parse(_ text: String) throws -> AppJSON {
        try parse(Data(text.utf8))
    }

    init(foundation value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let n as NSNumber:
            // CFBoolean is an NSNumber; tell them apart by type id.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map(AppJSON.init(foundation:)))
        case let o as [String: Any]: self = .object(try o.mapValues(AppJSON.init(foundation:)))
        default: throw CocoaError(.propertyListReadCorrupt)
        }
    }

    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let v): v
        case .number(let v): v
        case .string(let v): v
        case .array(let v): v.map(\.foundation)
        case .object(let v): v.mapValues(\.foundation)
        }
    }

    /// Compact JSON text (sorted keys, so equal values serialize equally).
    public var jsonText: String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated extension AppJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Double.self) { self = .number(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([AppJSON].self) { self = .array(v) }
        else { self = .object(try container.decode([String: AppJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

nonisolated extension AppJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: AppJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AppJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}
