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
/// Grammar (kept deliberately small and shell-safe):
/// - A placeholder is `{{` … `}}` whose inner text contains no `{`, `}`, or
///   newline.
/// - The name is the text before the first `=`; an optional default value is
///   the text after it. Both are trimmed of surrounding whitespace.
/// - A name must be non-empty and contain only letters, digits, spaces, or
///   `_ - .`. Anything else (`$`, `(`, `/`, `|`, …) makes the braces literal so
///   ordinary shell snippets that happen to use `{{` are never mistaken for a
///   variable.
enum CmuxCommandVariableParser {
    /// Returns the ordered, de-duplicated variables found in `command`,
    /// preserving first-occurrence order. When the same name appears more than
    /// once, the first occurrence's default value wins.
    static func variables(in command: String) -> [CmuxCommandVariable] {
        var seen = Set<String>()
        var result: [CmuxCommandVariable] = []
        for match in matches(in: command) where seen.insert(match.name).inserted {
            result.append(CmuxCommandVariable(name: match.name, defaultValue: match.defaultValue))
        }
        return result
    }

    /// Whether `command` contains at least one recognized variable placeholder.
    static func containsVariables(_ command: String) -> Bool {
        for _ in matches(in: command) { return true }
        return false
    }

    /// Replaces every recognized placeholder whose name is present in `values`
    /// with the corresponding value. Placeholders whose name is missing from
    /// `values` are left untouched so partial maps never corrupt the command.
    static func substitute(_ command: String, values: [String: String]) -> String {
        let found = matches(in: command)
        guard !found.isEmpty else { return command }
        var result = ""
        result.reserveCapacity(command.count)
        var cursor = command.startIndex
        for match in found {
            result.append(contentsOf: command[cursor..<match.range.lowerBound])
            if let value = values[match.name] {
                result.append(value)
            } else {
                result.append(contentsOf: command[match.range])
            }
            cursor = match.range.upperBound
        }
        result.append(contentsOf: command[cursor...])
        return result
    }

    // MARK: - Scanning

    private struct Match {
        let range: Range<String.Index>
        let name: String
        let defaultValue: String?
    }

    private static let allowedNameCharacters: CharacterSet = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-. "))

    private static func matches(in command: String) -> [Match] {
        var matches: [Match] = []
        var index = command.startIndex
        let end = command.endIndex
        while index < end {
            guard let open = command.range(of: "{{", range: index..<end) else { break }
            guard let close = command.range(of: "}}", range: open.upperBound..<end) else { break }
            let inner = command[open.upperBound..<close.lowerBound]
            let hasIllegalCharacter = inner.contains { character in
                character == "{" || character == "}" || character == "\n" || character == "\r"
            }
            if hasIllegalCharacter {
                // Not a clean placeholder; keep scanning just past the "{{".
                index = open.upperBound
                continue
            }
            if let parsed = parse(inner: String(inner)) {
                matches.append(
                    Match(
                        range: open.lowerBound..<close.upperBound,
                        name: parsed.name,
                        defaultValue: parsed.defaultValue
                    )
                )
                index = close.upperBound
            } else {
                index = open.upperBound
            }
        }
        return matches
    }

    private static func parse(inner: String) -> (name: String, defaultValue: String?)? {
        if let equals = inner.firstIndex(of: "=") {
            let name = inner[..<equals].trimmingCharacters(in: .whitespaces)
            let defaultValue = inner[inner.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard isValidName(name) else { return nil }
            return (name, defaultValue)
        }
        let name = inner.trimmingCharacters(in: .whitespaces)
        guard isValidName(name) else { return nil }
        return (name, nil)
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { allowedNameCharacters.contains($0) }
    }
}
