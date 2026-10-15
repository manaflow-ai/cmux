import Foundation

/// Parses `.env` text into secrets, with the rules `cmux vm env set --file` uses.
///
/// Blank lines and `#` comments are skipped; an optional `export ` prefix is dropped;
/// each line is `KEY=VALUE`. A matching pair of surrounding quotes is stripped with no
/// escape processing, and a trailing ` # comment` outside quotes is dropped. A quoted
/// value whose closing quote is not on the same line is refused, because a multi-line
/// value cannot be delivered. A repeated key keeps its last value at its first position.
/// Values are not validated here; ``CloudSecretVault/set(_:scope:source:)`` does that.
///
/// ``parse(_:)`` stops at the first bad line. ``parseLenient(_:)`` keeps every good line
/// and reports each bad one (and each `KEY=` with an empty value) by line number, so an
/// import can store what it can and say what it skipped.
/// lint:allow namespace-type: the contract's stateless parser entry point, shared by the CLI and the sheet.
public enum CloudSecretDotenv {
    /// What ``parseLenient(_:)`` found: the importable entries, and why each other
    /// non-blank, non-comment line was left out, in line order. Never carries a value.
    public struct LenientResult: Sendable, Equatable {
        public let inputs: [CloudSecretInput]
        public let skipped: [CloudSecretDotenvError]

        public init(inputs: [CloudSecretInput], skipped: [CloudSecretDotenvError]) {
            self.inputs = inputs
            self.skipped = skipped
        }
    }

    /// Strict: the first malformed line throws. An empty value (`KEY=`) is returned
    /// as an entry with an empty value; validation refuses it later.
    public static func parse(_ text: String) throws -> [CloudSecretInput] {
        var firstError: CloudSecretDotenvError?
        let inputs = scan(text, skipEmptyValues: false) { error in
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
        return inputs
    }

    /// Lenient: every good line is kept; a malformed line or an empty value is
    /// reported in ``LenientResult/skipped`` with its line number instead of failing
    /// the whole file. A key whose later line was skipped keeps its earlier value.
    public static func parseLenient(_ text: String) -> LenientResult {
        var skipped: [CloudSecretDotenvError] = []
        let inputs = scan(text, skipEmptyValues: true) { skipped.append($0) }
        return LenientResult(inputs: inputs, skipped: skipped)
    }

    private static func scan(
        _ text: String,
        skipEmptyValues: Bool,
        onBadLine: (CloudSecretDotenvError) -> Void
    ) -> [CloudSecretInput] {
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
                onBadLine(CloudSecretDotenvError(line: lineNumber, reason: .expectedAssignment))
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard CloudEnvDelivery.isValidKey(key) else {
                onBadLine(CloudSecretDotenvError(line: lineNumber, reason: .invalidName(key)))
                continue
            }
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(rawValue) else {
                onBadLine(CloudSecretDotenvError(line: lineNumber, reason: .multilineValue(key)))
                continue
            }
            if skipEmptyValues, value.isEmpty {
                onBadLine(CloudSecretDotenvError(line: lineNumber, reason: .emptyValue(key)))
                continue
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
