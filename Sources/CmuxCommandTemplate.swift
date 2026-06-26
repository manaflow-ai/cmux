import Foundation

/// A custom command string that may contain `{{variable}}` placeholders.
///
/// Wrapping the command in a value type keeps the placeholder logic on a
/// constructable type (`CmuxCommandTemplate(rawValue:)`) rather than a static
/// namespace.
///
/// Grammar (deliberately narrow so it does not regress shell commands that
/// embed Go/Handlebars/Mustache-style `{{…}}` templates):
/// - A placeholder is `{{` … `}}` whose inner text contains no `{`, `}`, or
///   newline.
/// - The name is the text before an optional `=`; the text after `=` is a
///   default value. Both are trimmed of surrounding whitespace.
/// - The name must be a *bare identifier*: a letter or `_` followed by letters,
///   digits, `_`, or `-`. Anything else — a leading `.` (`{{ .Env.FOO }}`),
///   internal spaces (`{{ range .Items }}`), pipes, or function calls — is left
///   completely untouched.
/// - A placeholder is only treated as a cmux variable when it appears at an
///   **unquoted** shell position. A `{{name}}` inside single or double quotes
///   (e.g. `gomplate -i '{{tag}}'`) is left literal and runs unchanged, so
///   existing template commands are not intercepted. This also means the
///   substituted value is always inserted at an unquoted position, where it can
///   be safely POSIX-quoted as a single argument.
struct CmuxCommandTemplate {
    /// The raw command string, exactly as written in `cmux.json`.
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The ordered, de-duplicated variables in the command, preserving
    /// first-occurrence order. When the same name appears more than once, the
    /// first occurrence's default value wins.
    var variables: [CmuxCommandVariable] {
        guard rawValue.contains("{{") else { return [] }
        var seen = Set<String>()
        var result: [CmuxCommandVariable] = []
        for case let .variable(variable, _) in scan() where seen.insert(variable.name).inserted {
            result.append(variable)
        }
        return result
    }

    /// Whether the command contains at least one recognized variable placeholder.
    var containsVariables: Bool {
        guard rawValue.contains("{{") else { return false }
        for case .variable in scan() { return true }
        return false
    }

    /// Resolves the command for execution: replaces every recognized
    /// placeholder whose name is present in `values` with its value as a single
    /// POSIX-quoted shell argument, leaves placeholders whose name is missing
    /// from `values` untouched, leaves non-identifier `{{…}}` template
    /// expressions untouched, and strips the escaping backslash from any
    /// `\{{…}}` so it becomes a literal `{{…}}`.
    ///
    /// Values are shell-quoted so that whatever the user types is passed as one
    /// literal argument — a value like `main; rm -rf /` cannot break out of the
    /// command and run as separate shell words.
    func substituting(_ values: [String: String]) -> String {
        guard rawValue.contains("{{") else { return rawValue }
        var result = ""
        result.reserveCapacity(rawValue.count)
        for token in scan() {
            switch token {
            case .literal(let text):
                result.append(text)
            case .variable(let variable, let raw):
                if let value = values[variable.name] {
                    result.append(Self.shellQuote(value))
                } else {
                    result.append(raw)
                }
            }
        }
        return result
    }

    /// Wraps `value` in POSIX single quotes so it is a single literal shell
    /// argument, escaping any embedded single quotes as `'\''`.
    ///
    /// The resolved command is delivered as interactive terminal input, so the
    /// line editor (readline/zle) interprets control bytes — Ctrl-U, ESC, an
    /// embedded newline — *before* the shell parses the quotes. A value such as
    /// `\u{15}rm -rf ~ #` could otherwise clear the quoted prefix and run as its
    /// own command. Drop C0/C1 control characters and DEL from the value first
    /// so quoting is actually sufficient; legitimate argument values never need
    /// them.
    static func shellQuote(_ value: String) -> String {
        let stripped = value.unicodeScalars.filter { scalar in
            !(scalar.value <= 0x1F || scalar.value == 0x7F
                || (scalar.value >= 0x80 && scalar.value <= 0x9F))
        }
        let escaped = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    // MARK: - Scanning

    private enum Token {
        /// Text emitted verbatim (plain text, quoted text, and unrecognized
        /// `{{…}}` template expressions).
        case literal(String)
        /// A recognized variable placeholder; `raw` is the original `{{…}}`
        /// text used when no value is supplied.
        case variable(CmuxCommandVariable, raw: String)
    }

    /// Walks the command tracking single/double shell-quote state (honouring
    /// backslash escapes outside single quotes), recognizing a `{{identifier}}`
    /// placeholder only when it appears at an unquoted position.
    private func scan() -> [Token] {
        let command = rawValue
        var tokens: [Token] = []
        var literalStart = command.startIndex
        var index = command.startIndex
        let end = command.endIndex
        var inSingleQuote = false
        var inDoubleQuote = false

        func flushLiteral(upTo upperBound: String.Index) {
            if literalStart < upperBound {
                tokens.append(.literal(String(command[literalStart..<upperBound])))
            }
        }

        while index < end {
            let character = command[index]

            if inSingleQuote {
                // Inside single quotes nothing is special except the closing
                // quote — not even backslash.
                if character == "'" { inSingleQuote = false }
                index = command.index(after: index)
                continue
            }

            if character == "\\" {
                // A backslash escapes the next character in unquoted and
                // double-quoted text, so e.g. `\"` does not change quote state.
                let next = command.index(after: index)
                index = next < end ? command.index(after: next) : end
                continue
            }

            if inDoubleQuote {
                if character == "\"" { inDoubleQuote = false }
                index = command.index(after: index)
                continue
            }

            // Unquoted context: a `{{identifier}}` here is a cmux variable.
            if character == "{" {
                let afterFirstBrace = command.index(after: index)
                if afterFirstBrace < end, command[afterFirstBrace] == "{" {
                    let innerStart = command.index(after: afterFirstBrace)
                    if let close = command.range(of: "}}", range: innerStart..<end) {
                        let inner = command[innerStart..<close.lowerBound]
                        let innerHasIllegalCharacter = inner.contains { c in
                            c == "{" || c == "}" || c == "\n" || c == "\r"
                        }
                        if !innerHasIllegalCharacter, let parsed = Self.parse(inner: String(inner)) {
                            flushLiteral(upTo: index)
                            tokens.append(
                                .variable(
                                    CmuxCommandVariable(name: parsed.name, defaultValue: parsed.defaultValue),
                                    raw: String(command[index..<close.upperBound])
                                )
                            )
                            index = close.upperBound
                            literalStart = index
                            continue
                        }
                    }
                    // Not a recognized placeholder; skip past "{{" and keep
                    // scanning the contents for quote state.
                    index = innerStart
                    continue
                }
            }

            if character == "'" {
                inSingleQuote = true
            } else if character == "\"" {
                inDoubleQuote = true
            }
            index = command.index(after: index)
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
