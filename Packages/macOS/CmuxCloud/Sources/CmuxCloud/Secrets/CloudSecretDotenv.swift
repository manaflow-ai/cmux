import Foundation

/// Parses `.env` text into secrets, with the rules `cmux vm env set --file` uses.
///
/// Blank lines and `#` comments are skipped; an optional `export ` prefix is dropped;
/// each line is `KEY=VALUE`. A matching pair of surrounding quotes is stripped with no
/// escape processing, and a trailing ` # comment` outside quotes is dropped. A quoted
/// value whose closing quote is not on the same line is refused, because a multi-line
/// value cannot be delivered. A repeated key keeps its last value at its first position.
/// Values are not validated here; ``CloudSecretVault/set(_:scope:source:)`` does that.
/// lint:allow namespace-type: the contract's stateless parser entry point, shared by the CLI and the sheet.
public enum CloudSecretDotenv {
    public static func parse(_ text: String) throws -> [CloudSecretInput] {
        var order: [String] = []
        var values: [String: String] = [:]
        // "\r\n" is one Character, so normalize it before splitting on "\n".
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw CloudSecretDotenvError(line: lineNumber, reason: .expectedAssignment)
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard CloudEnvDelivery.isValidKey(key) else {
                throw CloudSecretDotenvError(line: lineNumber, reason: .invalidName(key))
            }
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(rawValue) else {
                throw CloudSecretDotenvError(line: lineNumber, reason: .multilineValue(key))
            }
            if values[key] == nil { order.append(key) }
            values[key] = value
        }
        return order.compactMap { key in values[key].map { CloudSecretInput(name: key, value: $0) } }
    }

    /// One value, or `nil` when it opens a quote it never closes.
    static func parseValue(_ value: String) -> String? {
        if let quote = value.first, quote == "\"" || quote == "'" {
            var escaped = false
            var closed = false
            for index in value.indices.dropFirst() {
                let character = value[index]
                if character == quote, !escaped {
                    closed = true
                    let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    if suffix.isEmpty || suffix.hasPrefix("#") {
                        return String(value[value.index(after: value.startIndex)..<index])
                    }
                }
                escaped = character == "\\" && !escaped
            }
            if !closed { return nil }
        }
        if let comment = value.range(of: "[ \\t]+#", options: .regularExpression) {
            return value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
