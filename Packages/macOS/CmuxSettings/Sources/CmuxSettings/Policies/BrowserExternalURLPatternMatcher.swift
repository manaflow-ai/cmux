import Foundation

/// Normalizes URL rules and evaluates them with bounded, precompiled matchers.
struct BrowserExternalURLPatternMatcher: Sendable {
    /// The largest number of rules retained by one policy snapshot.
    private let maximumPatternCount = 256
    /// The largest number of array elements inspected by one policy snapshot.
    /// This keeps comment/duplicate-only legacy arrays from causing an
    /// unbounded scan before the effective rule limit is reached.
    private let maximumInputValueCount = 512
    /// The largest individual rule accepted for matching.
    private let maximumPatternLength = 4096
    /// The total rule text retained by one policy snapshot.
    private let maximumTotalPatternLength = 65_536
    private let regexSafety = BrowserExternalURLRegexSafety()

    /// The normalized rules represented by this matcher.
    private(set) var patterns: [String] = []
    private var compiledPatterns: [BrowserExternalURLCompiledPattern] = []

    /// Builds a normalized matcher from line-oriented or array-backed values.
    init(patterns: [String]) {
        self.patterns = normalizedPatterns(from: patterns)
        self.compiledPatterns = self.patterns.map(compile)
    }

    /// Builds a normalized matcher from a property-list value.
    init(rawValue: Any?) {
        if let values = rawValue as? [String] {
            self.init(patterns: values)
        } else if let values = rawValue as? NSArray {
            let limitedValues = Array(values.prefix(512))
            let strings = limitedValues.compactMap { $0 as? String }
            self.init(patterns: strings.count == limitedValues.count ? strings : [])
        } else if let value = rawValue as? String {
            self.init(patterns: [value])
        } else {
            self.init(patterns: [])
        }
    }

    /// Returns whether one of the precompiled rules matches `target`.
    func matches(_ target: String) -> Bool {
        compiledPatterns.contains { $0.matches(target) }
    }

    /// Converts a legacy array value to the newline text expected by Settings.
    func legacyArrayStringValue(from rawValue: Any?) -> String? {
        guard let values = arrayValues(from: rawValue) else { return nil }
        return normalizedPatterns(from: values).joined(separator: "\n")
    }

    /// Extracts supported string representations from a UserDefaults value.
    func stringValues(from rawValue: Any?) -> [String] {
        if let values = rawValue as? [String] {
            return values
        }
        if let values = rawValue as? NSArray {
            return values.prefix(maximumInputValueCount).compactMap { $0 as? String }
        }
        if let value = rawValue as? String {
            return [value]
        }
        return []
    }

    private func compile(_ pattern: String) -> BrowserExternalURLCompiledPattern {
        guard pattern.utf8.prefix(maximumPatternLength + 1).count <= maximumPatternLength else {
            return BrowserExternalURLCompiledPattern(unmatchable: ())
        }

        if pattern.lowercased().hasPrefix("re:") {
            let expression = String(pattern.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserExternalURLCompiledPattern(regex: makeRegex(expression))
        }

        if pattern.contains("*") || pattern.contains("?") {
            guard isLegacyRegexWildcardPattern(pattern) else {
                return BrowserExternalURLCompiledPattern(
                    wildcard: BrowserExternalURLWildcardPattern(pattern: pattern)
                )
            }
        }

        if isRegexShaped(pattern) {
            return BrowserExternalURLCompiledPattern(
                literalFallback: pattern,
                regex: makeRegex(pattern)
            )
        }

        return BrowserExternalURLCompiledPattern(literal: pattern)
    }

    private func makeRegex(_ expression: String) -> NSRegularExpression? {
        guard regexSafety.accepts(expression) else { return nil }
        return try? NSRegularExpression(
            pattern: expression,
            options: [.caseInsensitive]
        )
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

    private func normalizedPatterns(from values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var totalLength = 0
        for value in values.prefix(maximumInputValueCount) {
            guard totalLength < maximumTotalPatternLength else { return result }
            let boundedValue = String(value.prefix(maximumTotalPatternLength))
            for token in boundedValue.components(separatedBy: .newlines) {
                let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !normalized.hasPrefix("#") else { continue }
                guard seen.insert(normalized).inserted else { continue }
                guard result.count < maximumPatternCount,
                      totalLength + normalized.count <= maximumTotalPatternLength else {
                    return result
                }
                result.append(normalized)
                totalLength += normalized.count
            }
        }
        return result
    }

    private func arrayValues(from rawValue: Any?) -> [String]? {
        if let values = rawValue as? [String] {
            return values
        }
        guard let values = rawValue as? NSArray else {
            return nil
        }
        let limitedValues = Array(values.prefix(maximumInputValueCount))
        let strings = limitedValues.compactMap { $0 as? String }
        return strings.count == limitedValues.count ? strings : nil
    }
}
