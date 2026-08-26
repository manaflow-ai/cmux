import Foundation

/// Parses and matches the line-oriented URL rule syntax used by the browser policy.
struct BrowserExternalURLPatternMatcher: Equatable, Sendable {
    func matches(pattern: String, target: String) -> Bool {
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

    func legacyArrayStringValue(from rawValue: Any?) -> String? {
        guard let values = arrayValues(from: rawValue) else { return nil }
        return normalizedPatterns(from: values).joined(separator: "\n")
    }

    func normalizedPatterns(from values: [String]) -> [String] {
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

    func stringValues(from rawValue: Any?) -> [String] {
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

    private func regexMatches(_ expression: String, target: String) -> Bool {
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

    private func isRegexShaped(_ pattern: String) -> Bool {
        pattern.contains(where: { character in
            "\\^$+()[]{}|".contains(character)
        }) || pattern.contains(".*") || pattern.contains(".+")
    }

    private func isLegacyRegexWildcardPattern(_ pattern: String) -> Bool {
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

    private func wildcardRegex(for pattern: String) -> String {
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

    private func arrayValues(from rawValue: Any?) -> [String]? {
        if let values = rawValue as? [String] {
            return values
        }
        guard let values = rawValue as? NSArray else {
            return nil
        }
        let strings = values.compactMap { $0 as? String }
        return strings.count == values.count ? strings : nil
    }
}
