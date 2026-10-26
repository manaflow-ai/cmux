#if DEBUG || CMUX_BENCH_HOOKS
extension OracleValue {
    /// The value as canonical JSON: keys sorted by code point, no whitespace, non-ASCII text as is,
    /// an integral number with no fraction. This is the text scripts/cmux-next/oracle/normalize.py
    /// hashes (`json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False)`), so a hash of
    /// it compares across the app and the runner. It is taken before normalization: ids are raw.
    public var canonicalJSON: String {
        var text = ""
        Self.write(self, to: &text)
        return text
    }

    private static func write(_ value: OracleValue, to text: inout String) {
        switch value {
        case .null: text += "null"
        case .bool(let flag): text += flag ? "true" : "false"
        case .number(let number): text += canonicalNumber(number)
        case .string(let string): writeString(string, to: &text)
        case .array(let items):
            text += "["
            for (index, item) in items.enumerated() {
                if index > 0 { text += "," }
                write(item, to: &text)
            }
            text += "]"
        case .object(let members):
            text += "{"
            let keys = members.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for (index, key) in keys.enumerated() {
                if index > 0 { text += "," }
                writeString(key, to: &text)
                text += ":"
                if let member = members[key] { write(member, to: &text) }
            }
            text += "}"
        }
    }

    /// An integral number below 2^53 as an integer (the socket sends it so and Python reads an
    /// int); any other finite number in the shortest form that reads back the same; a non-finite
    /// one, which JSON cannot carry, as null.
    static func canonicalNumber(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 { return String(Int64(number)) }
        return "\(number)"
    }

    private static func writeString(_ string: String, to text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }
}
#endif
