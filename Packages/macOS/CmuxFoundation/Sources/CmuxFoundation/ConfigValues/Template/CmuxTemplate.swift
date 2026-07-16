import Foundation

/// Literal text that may contain cmux `{{variable}}` placeholders.
///
/// The grammar intentionally matches custom-command variables from #6898:
/// `{{name}}` and `{{name=default}}`, with a letter-or-underscore-leading name
/// containing letters, digits, `_`, or `-`. Invalid template expressions are
/// preserved. Prefixing a recognized placeholder with `\` keeps it literal and
/// removes that escaping backslash.
public struct CmuxTemplate: Sendable {
    /// The unresolved source text.
    public let rawValue: String

    /// Creates a template from unresolved source text.
    ///
    /// - Parameter rawValue: Text that may contain cmux placeholders.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Variables in first-occurrence order, de-duplicated by name.
    ///
    /// When a name occurs more than once, the first occurrence's inline default
    /// wins, matching the custom-command behavior from #6898.
    public var variables: [CmuxTemplateVariable] {
        var seen = Set<String>()
        return matches.compactMap { match in
            guard let variable = match.variable,
                  seen.insert(variable.name).inserted else {
                return nil
            }
            return variable
        }
    }

    /// Whether the text contains a recognized, unescaped cmux placeholder.
    public var containsVariables: Bool {
        matches.contains { $0.variable != nil }
    }

    /// Replaces recognized placeholders found in `values` and preserves any
    /// unresolved placeholders verbatim.
    ///
    /// Substitution is literal because workspace values also fill paths, URLs,
    /// titles, and environment values. Shell-command callers that accept
    /// interactive, untrusted values should quote those values before passing
    /// them here, as #6898 does for custom commands.
    ///
    /// - Parameter values: Values keyed by placeholder name.
    /// - Returns: The substituted text.
    public func substituting(_ values: [String: String]) -> String {
        let matches = matches
        guard !matches.isEmpty else { return rawValue }

        let characters = Array(rawValue)
        var result = ""
        result.reserveCapacity(characters.count)
        var cursor = 0
        for match in matches {
            result.append(contentsOf: characters[cursor..<match.range.lowerBound])
            if match.isEscaped {
                result.append(contentsOf: characters[(match.range.lowerBound + 1)..<match.range.upperBound])
            } else if let variable = match.variable, let value = values[variable.name] {
                result.append(value)
            } else {
                result.append(contentsOf: characters[match.range])
            }
            cursor = match.range.upperBound
        }
        result.append(contentsOf: characters[cursor...])
        return result
    }

    private struct Match {
        let variable: CmuxTemplateVariable?
        let range: Range<Int>
        let isEscaped: Bool
    }

    private var matches: [Match] {
        guard rawValue.contains("{{") else { return [] }
        let characters = Array(rawValue)
        var result: [Match] = []
        var index = 0

        while index + 1 < characters.count {
            let isEscaped = characters[index] == "\\"
                && index + 2 < characters.count
                && characters[index + 1] == "{"
                && characters[index + 2] == "{"
            let openingIndex = isEscaped ? index + 1 : index
            guard characters[openingIndex] == "{",
                  openingIndex + 1 < characters.count,
                  characters[openingIndex + 1] == "{" else {
                index += 1
                continue
            }

            let innerStart = openingIndex + 2
            guard let boundary = Self.candidateBoundary(in: characters, from: innerStart) else {
                break
            }
            if characters[boundary] == "{" {
                // Include the preceding character so escapes and overlapping
                // opening braces keep their normal recognition semantics.
                index = boundary - 1
                continue
            }
            let close = boundary
            let inner = characters[innerStart..<close]
            let hasIllegalCharacter = inner.contains { character in
                character == "{" || character == "}" || character == "\n" || character == "\r"
            }
            if !hasIllegalCharacter, let variable = Self.parseVariable(String(inner)) {
                result.append(Match(
                    variable: isEscaped ? nil : variable,
                    range: index..<(close + 2),
                    isEscaped: isEscaped
                ))
            }
            // Skip the entire candidate. This keeps malformed input linear
            // instead of repeatedly rescanning overlapping suffixes.
            index = close + 2
        }
        return result
    }

    /// Returns the next candidate-closing braces or a nested opening brace.
    private static func candidateBoundary(in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + 1 < characters.count {
            if characters[index] == "{" {
                return index
            }
            if characters[index] == "}", characters[index + 1] == "}" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func parseVariable(_ inner: String) -> CmuxTemplateVariable? {
        let name: String
        let defaultValue: String?
        if let equals = inner.firstIndex(of: "=") {
            name = inner[..<equals].trimmingCharacters(in: .whitespaces)
            defaultValue = inner[inner.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
        } else {
            name = inner.trimmingCharacters(in: .whitespaces)
            defaultValue = nil
        }
        guard CmuxTemplateVariable.isValidName(name) else { return nil }
        return CmuxTemplateVariable(name: name, defaultValue: defaultValue)
    }
}
