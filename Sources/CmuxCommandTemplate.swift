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
        for match in Self.variableMatches(in: Array(rawValue))
        where seen.insert(match.variable.name).inserted {
            result.append(match.variable)
        }
        return result
    }

    /// Whether the command contains at least one recognized variable placeholder.
    var containsVariables: Bool {
        guard rawValue.contains("{{") else { return false }
        return !Self.variableMatches(in: Array(rawValue)).isEmpty
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
        let chars = Array(rawValue)
        let matches = Self.variableMatches(in: chars)
        guard !matches.isEmpty else { return rawValue }
        var result = ""
        result.reserveCapacity(chars.count)
        var cursor = 0
        for match in matches {
            result.append(String(chars[cursor..<match.range.lowerBound]))
            if let value = values[match.variable.name] {
                result.append(Self.shellQuote(value))
            } else {
                result.append(String(chars[match.range]))
            }
            cursor = match.range.upperBound
        }
        result.append(String(chars[cursor...]))
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

    /// Finds the `{{identifier}}` placeholders that sit at unquoted shell-word
    /// positions, returning each variable with its character range in `chars`.
    ///
    /// The scan tracks single/double shell-quote state (honouring backslash
    /// escapes outside single quotes), here-doc bodies (`<<EOF … EOF`), and `#`
    /// comments, so quoted text, here-doc bodies, and comments are left
    /// untouched and existing template commands run unchanged.
    private static func variableMatches(
        in chars: [Character]
    ) -> [(variable: CmuxCommandVariable, range: Range<Int>)] {
        var matches: [(variable: CmuxCommandVariable, range: Range<Int>)] = []
        let count = chars.count
        var index = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        // FIFO of here-doc delimiters opened on the current line whose bodies
        // are skipped once the line's newline is reached.
        var pendingHeredocs: [(delimiter: String, stripTabs: Bool)] = []

        while index < count {
            let character = chars[index]

            if inSingleQuote {
                // Inside single quotes nothing is special except the closing
                // quote — not even backslash.
                if character == "'" { inSingleQuote = false }
                index += 1
                continue
            }

            if character == "\\" {
                // A backslash escapes the next character in unquoted and
                // double-quoted text, so e.g. `\"` does not change quote state.
                index += (index + 1 < count) ? 2 : 1
                continue
            }

            if inDoubleQuote {
                if character == "\"" { inDoubleQuote = false }
                index += 1
                continue
            }

            // Unquoted context.
            if character == "\n" {
                index += 1
                if !pendingHeredocs.isEmpty {
                    index = skipHeredocBodies(chars, from: index, delimiters: pendingHeredocs)
                    pendingHeredocs.removeAll()
                }
                continue
            }

            // `#` at a word boundary starts a comment that runs to end of line.
            if character == "#", isCommentStart(chars, at: index) {
                while index < count, chars[index] != "\n" { index += 1 }
                continue
            }

            if character == "<", index + 1 < count, chars[index + 1] == "<" {
                if index + 2 < count, chars[index + 2] == "<" {
                    // `<<<` here-string: the following word is a normal shell
                    // word, so skip the operator and keep scanning it.
                    index += 3
                    continue
                }
                // `<<`/`<<-` here-doc: queue the delimiter and skip the body at
                // the next newline so the literal body is left unchanged.
                index = consumeHeredocOperator(chars, from: index, into: &pendingHeredocs)
                continue
            }

            // A `{{identifier}}` at this unquoted position is a cmux variable.
            if character == "{", index + 1 < count, chars[index + 1] == "{" {
                let innerStart = index + 2
                if let close = indexOfCloseBraces(chars, from: innerStart) {
                    let inner = chars[innerStart..<close]
                    let innerHasIllegalCharacter = inner.contains { c in
                        c == "{" || c == "}" || c == "\n" || c == "\r"
                    }
                    if !innerHasIllegalCharacter, let parsed = parse(inner: String(inner)) {
                        matches.append((
                            CmuxCommandVariable(name: parsed.name, defaultValue: parsed.defaultValue),
                            index..<(close + 2)
                        ))
                        index = close + 2
                        continue
                    }
                }
                // Not a recognized placeholder; skip past "{{".
                index = innerStart
                continue
            }

            if character == "'" {
                inSingleQuote = true
            } else if character == "\"" {
                inDoubleQuote = true
            }
            index += 1
        }

        return matches
    }

    /// Whether `chars[i]` (a `#`) begins a shell comment: it must sit at a word
    /// boundary (start of input or after unquoted whitespace / `;` / `&` / `|`
    /// / `(`).
    private static func isCommentStart(_ chars: [Character], at i: Int) -> Bool {
        guard i > 0 else { return true }
        switch chars[i - 1] {
        case " ", "\t", "\n", ";", "&", "|", "(": return true
        default: return false
        }
    }

    /// Parses a `<<`/`<<-` here-doc operator and its delimiter starting at `i`
    /// (the first `<`), appending the delimiter to `pending`. Returns the index
    /// just past the delimiter word.
    private static func consumeHeredocOperator(
        _ chars: [Character],
        from i: Int,
        into pending: inout [(delimiter: String, stripTabs: Bool)]
    ) -> Int {
        let count = chars.count
        var j = i + 2
        var stripTabs = false
        if j < count, chars[j] == "-" { stripTabs = true; j += 1 }
        while j < count, chars[j] == " " || chars[j] == "\t" { j += 1 }

        var delimiter = ""
        loop: while j < count {
            let c = chars[j]
            switch c {
            case "'", "\"":
                let quote = c
                j += 1
                while j < count, chars[j] != quote { delimiter.append(chars[j]); j += 1 }
                if j < count { j += 1 }
            case "\\":
                j += 1
                if j < count { delimiter.append(chars[j]); j += 1 }
            case " ", "\t", "\n", ";", "&", "|", "<", ">", "(", ")":
                break loop
            default:
                delimiter.append(c)
                j += 1
            }
        }
        if !delimiter.isEmpty { pending.append((delimiter, stripTabs)) }
        return j
    }

    /// Skips here-doc bodies starting at `start`, one per queued delimiter, and
    /// returns the index just past the final terminator line.
    private static func skipHeredocBodies(
        _ chars: [Character],
        from start: Int,
        delimiters: [(delimiter: String, stripTabs: Bool)]
    ) -> Int {
        let count = chars.count
        var index = start
        for (delimiter, stripTabs) in delimiters {
            while index < count {
                let lineStart = index
                while index < count, chars[index] != "\n" { index += 1 }
                var line = String(chars[lineStart..<index])
                if stripTabs { line = String(line.drop { $0 == "\t" }) }
                if index < count { index += 1 }  // consume the newline
                if line == delimiter { break }
            }
        }
        return index
    }

    /// Index of the first `}` in the next `}}` at or after `start`, or `nil`.
    private static func indexOfCloseBraces(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "}", chars[i + 1] == "}" { return i }
            i += 1
        }
        return nil
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
