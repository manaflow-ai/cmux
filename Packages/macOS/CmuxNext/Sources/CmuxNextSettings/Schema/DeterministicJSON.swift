public import Foundation

/// A JSON writer whose output does not depend on the toolchain, for the files
/// the exports check in (`schemas/settings/settings-schema.json`,
/// `docs/mdm/com.manaflow.cmux.json`). Foundation's `JSONSerialization`
/// prints doubles differently across Xcode releases (`0.1` on Xcode 26,
/// `0.10000000000000001` on Xcode 27), which made those files stale on one
/// toolchain or the other. This writer formats every number itself, in the
/// shortest form that reads back to the same `Double`, and keeps the layout
/// `JSONSerialization` used (`"key" : value`, two-space indent, sorted keys,
/// unescaped slashes), so the files change only where a number was long.
public struct DeterministicJSON {
    public init() {}

    public nonisolated enum Failure: Error, Equatable {
        /// JSON has no form for NaN or infinity.
        case nonFiniteNumber
        /// A value that is not a JSON type (the name of its type).
        case unsupportedValue(String)
    }

    /// `object` (Foundation JSON types: dictionaries with `String` keys,
    /// arrays, `String`, `Bool`, integers, `Double`, `NSNull`) as JSON text.
    /// Keys are sorted by `keyOrder`. `pretty` uses the
    /// `JSONSerialization` `.prettyPrinted` layout.
    public func string(_ object: Any, pretty: Bool) throws -> String {
        var out = ""
        try write(object, pretty: pretty, indent: 0, into: &out)
        return out
    }

    /// The shortest decimal text that reads back to `value` (Swift's
    /// round-trip `description`, which the standard library computes the same
    /// way on every platform). Whole numbers below 1e15 print without a
    /// fraction (`1`, not `1.0`); exponents drop the sign and padding Swift
    /// adds (`1e-7`, not `1e-07`).
    public func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw Failure.nonFiniteNumber }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let text = value.description
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }),
              let exponent = Int(text[text.index(after: e)...])
        else { return text }
        return "\(text[..<e])e\(exponent)"
    }

    func write(_ value: Any, pretty: Bool, indent: Int, into out: inout String) throws {
        switch value {
        case let text as String: quote(text, into: &out)
        case is NSNull: out += "null"
        case let members as [String: Any]:
            try container("{", "}", members.keys.sorted(by: keyOrder),
                          pretty: pretty, indent: indent, into: &out) { key, out in
                quote(key, into: &out)
                out += pretty ? " : " : ":"
                try write(members[key] as Any, pretty: pretty, indent: indent + 1, into: &out)
            }
        case let items as [Any]:
            try container("[", "]", items, pretty: pretty, indent: indent, into: &out) { item, out in
                try write(item, pretty: pretty, indent: indent + 1, into: &out)
            }
        default: out += try scalar(value)
        }
    }

    /// Case-insensitive order, ties broken by exact scalar order: the order
    /// `JSONSerialization` `.sortedKeys` gave the checked-in files
    /// (`DisableAutoUpdate` sorts among the `d` keys), computed here with
    /// locale-free Swift string operations so it cannot move either.
    func keyOrder(_ lhs: String, _ rhs: String) -> Bool {
        let (a, b) = (lhs.lowercased(), rhs.lowercased())
        if a != b { return a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }
        return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
    }

    func container<Element>(
        _ open: String, _ close: String, _ elements: [Element], pretty: Bool, indent: Int, into out: inout String,
        element: (Element, inout String) throws -> Void
    ) rethrows {
        out += open
        let inner = String(repeating: "  ", count: indent + 1)
        for (index, item) in elements.enumerated() {
            if index > 0 { out += "," }
            if pretty { out += "\n" + inner }
            try element(item, &out)
        }
        // JSONSerialization prints an empty container as an open line, a
        // blank line, and the close; keep that so existing files do not churn.
        if pretty { out += (elements.isEmpty ? "\n\n" : "\n") + String(repeating: "  ", count: indent) }
        out += close
    }

    /// Exact native types first: on Darwin `as? Bool` also matches a boxed
    /// number, so the type is compared, not cast.
    func scalar(_ value: Any) throws -> String {
        switch ObjectIdentifier(type(of: value)) {
        case ObjectIdentifier(Bool.self): if let flag = value as? Bool { return flag ? "true" : "false" }
        case ObjectIdentifier(Double.self): if let double = value as? Double { return try number(double) }
        case ObjectIdentifier(Float.self): if let float = value as? Float { return try number(Double(float)) }
        case ObjectIdentifier(CGFloat.self): if let cgFloat = value as? CGFloat { return try number(Double(cgFloat)) }
        default: break
        }
        if let integer = value as? any BinaryInteger { return String(describing: integer) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return CFNumberIsFloatType(number) ? try self.number(number.doubleValue) : number.stringValue
        }
        throw Failure.unsupportedValue(String(describing: type(of: value)))
    }

    func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
