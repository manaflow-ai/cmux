import Foundation

/// Parses `.env` text into secrets, with the rules `cmux vm env set --file` uses.
///
/// Blank lines and `#` comments are skipped; an optional `export ` prefix is dropped;
/// each line is `KEY=VALUE`. A matching pair of surrounding quotes is stripped; inside
/// double quotes `\"` is a quote (no other escapes), inside single quotes nothing is an
/// escape. A trailing ` # comment` outside quotes is dropped. A quoted value whose
/// closing quote is not on the same line is refused, because a multi-line value cannot
/// be delivered, and so is one with other text after its closing quote. A repeated key keeps its last value at its first position.
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
            let value: String
            switch parseValue(rawValue) {
            case .value(let parsed):
                value = parsed
            case .unclosedQuote:
                onBadLine(CloudSecretDotenvError(line: lineNumber, reason: .multilineValue(key)))
                continue
            case .trailingText:
                onBadLine(CloudSecretDotenvError(line: lineNumber, reason: .trailingText(key)))
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

    /// What one raw value parses to.
    enum ParsedValue: Equatable {
        case value(String)
        /// It opens a quote it never closes on its line.
        case unclosedQuote
        /// It is quoted, with text other than a comment after the closing quote.
        case trailingText
    }

    static func parseValue(_ value: String) -> ParsedValue {
        guard let quote = value.first, quote == "\"" || quote == "'" else {
            if let comment = value.range(of: "[ \\t]+#", options: .regularExpression) {
                return .value(value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces))
            }
            return .value(value)
        }
        var unquoted = ""
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if quote == "\"", character == "\\", next < value.endIndex, value[next] == "\"" {
                unquoted.append("\"")
                index = value.index(after: next)
                continue
            }
            if character == quote {
                let suffix = value[next...].trimmingCharacters(in: .whitespaces)
                return suffix.isEmpty || suffix.hasPrefix("#") ? .value(unquoted) : .trailingText
            }
            unquoted.append(character)
            index = next
        }
        return .unclosedQuote
    }
}
