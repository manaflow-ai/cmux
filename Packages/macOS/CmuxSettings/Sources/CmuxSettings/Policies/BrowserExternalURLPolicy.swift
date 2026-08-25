import Foundation

/// Matches configured URL rules that should bypass the embedded browser.
///
/// Rules are stored as one string per line by the legacy settings surface, but
/// the JSON settings importer and older releases can leave them as an array in
/// `UserDefaults`. The policy accepts both representations so every browser
/// entry point evaluates the same effective rules.
public struct BrowserExternalURLPolicy: Equatable, Sendable {
    /// The legacy `UserDefaults` key used by the browser settings catalog.
    public static let userDefaultsKey = "browserExternalOpenPatterns"

    /// The normalized, non-empty rules used by this policy.
    public let patterns: [String]

    /// Creates a policy from a `UserDefaults` suite.
    ///
    /// - Parameter defaults: The preference suite containing the browser rules.
    public init(defaults: UserDefaults) {
        self.init(rawValue: defaults.object(forKey: Self.userDefaultsKey))
    }

    /// Creates a policy from explicit rule values.
    ///
    /// - Parameter patterns: Rules in either line-oriented or array form.
    public init(patterns: [String]) {
        self.patterns = Self.normalizedPatterns(from: patterns)
    }

    private init(rawValue: Any?) {
        self.patterns = Self.normalizedPatterns(from: Self.stringValues(from: rawValue))
    }

    /// Returns whether a URL matches at least one configured rule.
    public func matches(_ url: URL) -> Bool {
        matches(url.absoluteString)
    }

    /// Returns whether raw URL text matches at least one configured rule.
    public func matches(_ rawURL: String) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        return patterns.contains { pattern in
            Self.matches(pattern: pattern, target: target)
        }
    }

    private static func matches(pattern: String, target: String) -> Bool {
        if pattern.lowercased().hasPrefix("re:") {
            let expression = String(pattern.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return regexMatches(expression, target: target)
        }

        // Keep the documented plain-text substring behavior, while accepting
        // the regex-shaped rules users historically supplied to this setting.
        // A rule containing star/question wildcards is a glob by default, even
        // when it also contains regex metacharacters. The common unprefixed
        // `.*`/`.+` forms remain regexes for compatibility; use `re:` for any
        // other regex that also needs wildcard characters.
        if pattern.contains("*") || pattern.contains("?") {
            guard isLegacyRegexWildcardPattern(pattern) else {
                return regexMatches(wildcardRegex(for: pattern), target: target)
            }
        }

        if isRegexShaped(pattern) {
            if target.range(of: pattern, options: [.caseInsensitive]) != nil {
                return true
            }
            return regexMatches(pattern, target: target)
        }

        return target.range(of: pattern, options: [.caseInsensitive]) != nil
    }

    private static func regexMatches(_ expression: String, target: String) -> Bool {
        guard !expression.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: expression,
                  options: [.caseInsensitive]
              ) else {
            return false
        }
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        return regex.firstMatch(in: target, options: [], range: range) != nil
    }

    private static func isRegexShaped(_ pattern: String) -> Bool {
        pattern.contains(where: { character in
            "\\^$+()[]{}|".contains(character)
        }) || pattern.contains(".*") || pattern.contains(".+")
    }

    private static func isLegacyRegexWildcardPattern(_ pattern: String) -> Bool {
        var hasLegacyQuantifier = false
        var isEscaping = false
        var previousWasUnescapedDot = false

        for character in pattern {
            if isEscaping {
                isEscaping = false
                previousWasUnescapedDot = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                previousWasUnescapedDot = false
                continue
            }

            if character == "?" {
                return false
            }
            if character == "*" || character == "+" {
                if previousWasUnescapedDot {
                    hasLegacyQuantifier = true
                } else if character == "*" {
                    // A standalone star is a glob wildcard, even when a
                    // later literal period happens to form the text `.*`.
                    return false
                }
            }
            previousWasUnescapedDot = character == "."
        }

        return hasLegacyQuantifier
    }

    private static func wildcardRegex(for pattern: String) -> String {
        var expression = ""
        expression.reserveCapacity(pattern.count * 2)
        var isEscaping = false
        for character in pattern {
            if isEscaping {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            switch character {
            case "*":
                expression += ".*"
            case "?":
                expression += "."
            default:
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if isEscaping {
            expression += NSRegularExpression.escapedPattern(for: "\\")
        }
        return expression
    }

    private static func normalizedPatterns(from values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            for token in value.components(separatedBy: .newlines) {
                let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !normalized.hasPrefix("#") else { continue }
                guard seen.insert(normalized).inserted else { continue }
                result.append(normalized)
            }
        }
        return result
    }

    private static func stringValues(from rawValue: Any?) -> [String] {
        if let values = rawValue as? [String] {
            return values
        }
        if let values = rawValue as? NSArray {
            return values.compactMap { $0 as? String }
        }
        if let value = rawValue as? String {
            return [value]
        }
        return []
    }
}
