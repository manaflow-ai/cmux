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
    public var compactText: String {
        var out = ""
        appendCompactText(to: &out)
        return out
    }

    /// Appends ``compactText`` to `out` (one buffer, linear in the output size).
    public func appendCompactText(to out: inout String) {
        render(into: &out, indent: nil, level: 0, base: "")
    }

    /// Pretty JSON text. `baseIndent` prefixes every line after the first so
    /// the value can be spliced into an indented document.
    public func prettyText(indentUnit: String = "  ", baseIndent: String = "") -> String {
        var out = ""
        render(into: &out, indent: indentUnit, level: 0, base: baseIndent)
        return out
    }

    /// Appends the text of this value to `out`. Every level writes into the one buffer, so the
    /// cost is linear in the output (no per-level string building and re-concatenation).
    private func render(into out: inout String, indent: String?, level: Int, base: String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { out += String(Int(value)) } else { out += String(value) }
        case .string(let value): Self.appendQuoted(value, to: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            guard let indent else {
                out += "["
                for (index, item) in items.enumerated() {
                    if index > 0 { out += "," }
                    item.render(into: &out, indent: nil, level: 0, base: base)
                }
                out += "]"
                return
            }
            let inner = base + String(repeating: indent, count: level + 1)
            out += "[\n"
            for (index, item) in items.enumerated() {
                if index > 0 { out += ",\n" }
                out += inner
                item.render(into: &out, indent: indent, level: level + 1, base: base)
            }
            out += "\n"
            out += base
            for _ in 0..<level { out += indent }
            out += "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            let sorted = members.sorted { $0.key < $1.key }
            guard let indent else {
                out += "{"
                for (index, member) in sorted.enumerated() {
                    if index > 0 { out += "," }
                    Self.appendQuoted(member.key, to: &out)
                    out += ":"
                    member.value.render(into: &out, indent: nil, level: 0, base: base)
                }
                out += "}"
                return
            }
            let inner = base + String(repeating: indent, count: level + 1)
            out += "{\n"
            for (index, member) in sorted.enumerated() {
                if index > 0 { out += ",\n" }
                out += inner
                Self.appendQuoted(member.key, to: &out)
                out += ": "
                member.value.render(into: &out, indent: indent, level: level + 1, base: base)
            }
            out += "\n"
            out += base
            for _ in 0..<level { out += indent }
            out += "}"
        }
    }

    /// JSON string literal for `text`.
    public static func quote(_ text: String) -> String {
        var out = ""
        appendQuoted(text, to: &out)
        return out
    }

    private static let hexDigits: [Unicode.Scalar] = Array("0123456789abcdef".unicodeScalars)

    /// Appends the JSON string literal for `text` to `out`. Escapes `"`, `\\`, `\n`, `\r`, `\t`,
    /// backspace and form feed by name, other scalars below U+0020 as `\u00xx` (lowercase hex);
    /// every other scalar is copied as is.
    public static func appendQuoted(_ text: String, to out: inout String) {
        out += "\""
        // Fast path: nothing to escape (UTF-8 continuation and lead bytes are all >= 0x80).
        guard text.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) else {
            out += text
            out += "\""
            return
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00"
                    out.unicodeScalars.append(hexDigits[Int(scalar.value >> 4)])
                    out.unicodeScalars.append(hexDigits[Int(scalar.value & 0xF)])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
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
