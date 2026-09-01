import Foundation

/// Converts browser RPC values into their plain-text CLI representation.
struct BrowserValueTextFormatter {
    func string(from value: Any) -> String {
        if let dictionary = value as? [String: Any],
           dictionary["__cmux_t"] as? String == "undefined" {
            return "undefined"
        }
        if value is NSNull {
            return "null"
        }
        if let string = value as? String {
            return sanitizedTerminalString(string)
        }
        if let number = value as? NSNumber {
            return string(from: number)
        }
        if let array = value as? [Any], array.isEmpty {
            return "[]"
        }
        if let dictionary = value as? [String: Any], dictionary.isEmpty {
            return "{}"
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return sanitizedTerminalString(String(describing: value))
    }

    private func string(from number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }

        let value = number.doubleValue
        if value.isNaN {
            return "NaN"
        }
        if value == .infinity {
            return "Infinity"
        }
        if value == -.infinity {
            return "-Infinity"
        }
        return number.stringValue
    }

    /// Replace control and format scalars before page-controlled text reaches a terminal.
    private func sanitizedTerminalString(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            (scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format)
                ? Character("\u{FFFD}")
                : Character(scalar)
        })
    }
}
