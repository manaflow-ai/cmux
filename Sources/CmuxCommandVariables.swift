import Foundation

/// A `{{name}}` (or `{{name=default}}`) placeholder discovered in a custom
/// command's `command` string.
///
/// Variables let a single `commands` entry be reused with different values:
/// cmux prompts for each variable before running the command and substitutes
/// the entered values back into the shell string. The syntax intentionally
/// matches the existing `{{…}}` convention already used by Vault agent
/// templates so users only have to learn one placeholder form.
struct CmuxCommandVariable: Equatable, Sendable {
    /// The placeholder name, e.g. `environment` for `{{environment}}`.
    let name: String
    /// The optional default value parsed from `{{name=default}}`, used to
    /// pre-fill the prompt field. `nil` when the placeholder has no default.
    let defaultValue: String?
}

/// Parses and substitutes `{{variable}}` placeholders inside custom command
/// strings.
///
/// Grammar (deliberately narrow so it does not regress shell commands that
/// embed Go/Handlebars-style `{{…}}` templates):
/// - A placeholder is `{{` … `}}` whose inner text contains no `{`, `}`, or
///   newline.
/// - The name is the text before an optional `=`; the text after `=` is a
///   default value. Both are trimmed of surrounding whitespace.
/// - The name must be a *bare identifier*: a letter or `_` followed by letters,
///   digits, `_`, or `-`. Anything else — a leading `.` (`{{ .Env.FOO }}`),
///   internal spaces (`{{ range .Items }}`), pipes, or function calls — is left
///   completely untouched and runs as-is.
/// - Prefix the placeholder with a backslash (`\{{name}}`) to force a literal
///   `{{name}}`; cmux strips the backslash and never prompts for it.
enum CmuxCommandVariableParser {
    /// Returns the ordered, de-duplicated variables found in `command`,
    /// preserving first-occurrence order. When the same name appears more than
    /// once, the first occurrence's default value wins.
    static func variables(in command: String) -> [CmuxCommandVariable] {
        guard command.contains("{{") else { return [] }
        var seen = Set<String>()
        var result: [CmuxCommandVariable] = []
        for case let .variable(variable, _) in scan(command) where seen.insert(variable.name).inserted {
            result.append(variable)
        }
        return result
    }

    /// Whether `command` contains at least one recognized variable placeholder.
    static func containsVariables(_ command: String) -> Bool {
        guard command.contains("{{") else { return false }
        for case .variable in scan(command) { return true }
        return false
    }

    /// Resolves `command` for execution: replaces every recognized placeholder
    /// whose name is present in `values` with its value as a single
    /// POSIX-quoted shell argument, leaves placeholders whose name is missing
    /// from `values` untouched, leaves non-identifier `{{…}}` template
    /// expressions untouched, and strips the escaping backslash from any
    /// `\{{…}}` so it becomes a literal `{{…}}`.
    ///
    /// Values are shell-quoted so that whatever the user types is passed as one
    /// literal argument — a value like `main; rm -rf /` cannot break out of the
    /// command and run as separate shell words.
    static func substitute(_ command: String, values: [String: String]) -> String {
        guard command.contains("{{") else { return command }
        var result = ""
        result.reserveCapacity(command.count)
        for token in scan(command) {
            switch token {
            case .literal(let text):
                result.append(text)
            case .variable(let variable, let raw):
                if let value = values[variable.name] {
                    result.append(shellQuote(value))
                } else {
                    result.append(raw)
                }
            }
        }
        return result
    }

    /// Wraps `value` in POSIX single quotes so it is a single literal shell
    /// argument, escaping any embedded single quotes as `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Scanning

    private enum Token {
        /// Text emitted verbatim (plain text, escaped placeholders with the
        /// backslash removed, and unrecognized `{{…}}` template expressions).
        case literal(String)
        /// A recognized variable placeholder; `raw` is the original `{{…}}`
        /// text used when no value is supplied.
        case variable(CmuxCommandVariable, raw: String)
    }

    private static func scan(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var literalStart = command.startIndex
        var index = command.startIndex
        let end = command.endIndex

        func flushLiteral(upTo upperBound: String.Index) {
            if literalStart < upperBound {
                tokens.append(.literal(String(command[literalStart..<upperBound])))
            }
        }

        while index < end {
            guard let open = command.range(of: "{{", range: index..<end) else { break }
            guard let close = command.range(of: "}}", range: open.upperBound..<end) else {
                // No closing braces remain; everything left is literal text.
                break
            }

            let inner = command[open.upperBound..<close.lowerBound]
            let innerHasIllegalCharacter = inner.contains { character in
                character == "{" || character == "}" || character == "\n" || character == "\r"
            }
            if innerHasIllegalCharacter {
                // Not a clean placeholder; keep the "{{" in the literal run.
                index = open.upperBound
                continue
            }

            let isEscaped = open.lowerBound > command.startIndex
                && command[command.index(before: open.lowerBound)] == "\\"
            if isEscaped {
                // Drop the escaping backslash and emit a literal "{{…}}".
                let backslash = command.index(before: open.lowerBound)
                flushLiteral(upTo: backslash)
                tokens.append(.literal(String(command[open.lowerBound..<close.upperBound])))
                literalStart = close.upperBound
                index = close.upperBound
                continue
            }

            if let parsed = parse(inner: String(inner)) {
                flushLiteral(upTo: open.lowerBound)
                tokens.append(
                    .variable(
                        CmuxCommandVariable(name: parsed.name, defaultValue: parsed.defaultValue),
                        raw: String(command[open.lowerBound..<close.upperBound])
                    )
                )
                literalStart = close.upperBound
                index = close.upperBound
            } else {
                // A `{{…}}` that is not a bare identifier (template expression);
                // keep it in the literal run unchanged.
                index = close.upperBound
            }
        }

        flushLiteral(upTo: end)
        return tokens
    }

    private static func parse(inner: String) -> (name: String, defaultValue: String?)? {
        if let equals = inner.firstIndex(of: "=") {
            let name = inner[..<equals].trimmingCharacters(in: .whitespaces)
            let defaultValue = inner[inner.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard isValidIdentifier(name) else { return nil }
            return (name, defaultValue)
        }
        let name = inner.trimmingCharacters(in: .whitespaces)
        guard isValidIdentifier(name) else { return nil }
        return (name, nil)
    }

    private static let trailingNameCharacters: CharacterSet = CharacterSet.letters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "_-"))

    /// A bare identifier: a leading letter or `_`, then letters, digits, `_`, or
    /// `-`. Rejects dots, spaces, and everything used by template engines.
    private static func isValidIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { trailingNameCharacters.contains($0) }
    }
}
