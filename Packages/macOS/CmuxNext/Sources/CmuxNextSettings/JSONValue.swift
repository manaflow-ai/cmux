public import Foundation

/// A JSON value. Used for cmux.json documents and for the control socket's
/// wire format, so both agree on one representation.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ value: Int) { self = .number(Double(value)) }

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The number as an exact integer, or nil for fractions and non-numbers.
    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// The value at a key path, or nil when any step is missing.
    public func value(at path: [String]) -> JSONValue? {
        var current = self
        for key in path {
            guard let next = current[key] else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Foundation bridging

    /// Bridges a `JSONSerialization` object graph. Nil for unsupported types.
    public init?(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(array.count)
            for element in array {
                guard let item = JSONValue(foundation: element) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            var members: [String: JSONValue] = [:]
            members.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let item = JSONValue(foundation: element) else { return nil }
                members[key] = item
            }
            self = .object(members)
        default:
            return nil
        }
    }

    /// The `JSONSerialization`-compatible object graph.
    public var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { NSNumber(value: Int(value)) } else { NSNumber(value: value) }
        case .string(let value): value
        case .array(let items): items.map(\.foundationObject)
        case .object(let members): members.mapValues(\.foundationObject)
        }
    }

    /// Parses strict JSON text (use `JSONC.strip` first for cmux.json).
    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let value = JSONValue(foundation: object) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return value
    }

    /// Single-line JSON text with sorted keys.
    public var compactText: String { render(indent: nil, level: 0) }

    /// Pretty JSON text. `baseIndent` prefixes every line after the first so
    /// the value can be spliced into an indented document.
    public func prettyText(indentUnit: String = "  ", baseIndent: String = "") -> String {
        render(indent: indentUnit, level: 0, base: baseIndent)
    }

    private func render(indent: String?, level: Int, base: String = "") -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .string(let value): return Self.quote(value)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            guard let indent else { return "[" + items.map { $0.render(indent: nil, level: 0) }.joined(separator: ",") + "]" }
            let inner = base + String(repeating: indent, count: level + 1)
            let outer = base + String(repeating: indent, count: level)
            let body = items.map { inner + $0.render(indent: indent, level: level + 1, base: base) }
            return "[\n" + body.joined(separator: ",\n") + "\n" + outer + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let keys = members.keys.sorted()
            guard let indent else {
                return "{" + keys.map { Self.quote($0) + ":" + members[$0]!.render(indent: nil, level: 0) }.joined(separator: ",") + "}"
            }
            let inner = base + String(repeating: indent, count: level + 1)
            let outer = base + String(repeating: indent, count: level)
            let body = keys.map { inner + Self.quote($0) + ": " + members[$0]!.render(indent: indent, level: level + 1, base: base) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + outer + "}"
        }
    }

    /// JSON string literal for `text`.
    public static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
