import Foundation

/// Normalizes URL rules and evaluates them with bounded, precompiled matchers.
/// Ported from classic cmux (`CmuxSettings` `BrowserExternalURLPolicy`) so a
/// classic `browser.urlsToAlwaysOpenExternally` rule matches the same URLs.
nonisolated struct BrowserExternalURLPatternMatcher: Sendable {
    private let maximumTargetLength = 16_384
    /// Each wildcard receives an independent bounded slice so a costly rule
    /// cannot prevent a later valid rule from being considered.
    private let maximumMatchOperationsPerPattern = 32_768
    /// The largest number of rules retained by one policy snapshot.
    private let maximumPatternCount = 256
    /// The largest number of values inspected by one matcher. This keeps
    /// comment/duplicate-only lists from causing an unbounded scan before
    /// the effective rule limit is reached.
    private let maximumInputValueCount = 512
    /// The largest individual rule accepted for matching.
    private let maximumPatternLength = 4096
    /// The total rule text retained by one policy snapshot.
    private let maximumTotalPatternLength = 65_536
    private let regexSafety = BrowserExternalURLRegexSafety()

    /// The normalized rules represented by this matcher.
    private(set) var patterns: [String] = []
    private var compiledPatterns: [BrowserExternalURLCompiledPattern] = []

    /// Builds a normalized matcher from rules, one per value or line.
    init(patterns: [String]) {
        self.patterns = normalizedPatterns(from: patterns)
        self.compiledPatterns = self.patterns.map(compile)
    }

    /// Returns whether one of the precompiled rules matches `target`.
    func matches(_ target: String) -> Bool {
        guard target.utf8.prefix(maximumTargetLength + 1).count <= maximumTargetLength else {
            return false
        }

        let normalizedTargetString = compiledPatterns.contains(where: \.requiresNormalizedTarget)
            ? target.lowercased()
            : ""
        let normalizedTarget = normalizedTargetString.isEmpty
            ? []
            : normalizedTargetString.map(String.init)
        for pattern in compiledPatterns {
            var operationBudget = maximumMatchOperationsPerPattern
            if pattern.matches(
                target,
                normalizedTarget: normalizedTarget,
                normalizedTargetString: normalizedTargetString,
                operationBudget: &operationBudget
            ) {
                return true
            }
        }
        return false
    }

    private func compile(_ pattern: String) -> BrowserExternalURLCompiledPattern {
        guard pattern.utf8.prefix(maximumPatternLength + 1).count <= maximumPatternLength else {
            return BrowserExternalURLCompiledPattern(unmatchable: ())
        }

        if pattern.lowercased().hasPrefix("re:") {
            let expression = String(pattern.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let wildcard = linearWildcardPattern(from: expression) {
                return BrowserExternalURLCompiledPattern(wildcard: wildcard)
            }
            return BrowserExternalURLCompiledPattern(regex: makeRegex(expression))
        }

        if pattern.contains("*") || pattern.contains("?") {
            guard isLegacyRegexWildcardPattern(pattern) else {
                guard let wildcard = BrowserExternalURLWildcardPattern(pattern: pattern) else {
                    return BrowserExternalURLCompiledPattern(unmatchable: ())
                }
                return BrowserExternalURLCompiledPattern(wildcard: wildcard)
            }
        }

        if isRegexShaped(pattern) {
            if let wildcard = linearWildcardPattern(from: pattern) {
                return BrowserExternalURLCompiledPattern(wildcard: wildcard)
            }
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

    /// Converts the small, legacy `.*`/`.+` regex subset into the bounded glob
    /// matcher. This keeps repeated wildcard quantifiers linear while leaving
    /// grouping, classes, anchors, and other regex operators to the safety
    /// gate below.
    private func linearWildcardPattern(from expression: String) -> BrowserExternalURLWildcardPattern? {
        var wildcard = ""
        var hasWildcardQuantifier = false
        var index = expression.startIndex

        while index < expression.endIndex {
            let character = expression[index]
            let nextIndex = expression.index(after: index)

            if character == "." {
                if nextIndex < expression.endIndex {
                    switch expression[nextIndex] {
                    case "*":
                        wildcard.append("*")
                        hasWildcardQuantifier = true
                        index = expression.index(after: nextIndex)
                        continue
                    case "+":
                        // `.+` means at least one character. `?*` is the
                        // equivalent bounded-glob sequence.
                        wildcard.append("?*")
                        hasWildcardQuantifier = true
                        index = expression.index(after: nextIndex)
                        continue
                    default:
                        break
                    }
                }
                // A bare regex dot is a one-character wildcard; append the
                // glob token directly so it is not escaped as a literal `?`.
                wildcard.append("?")
                index = nextIndex
                continue
            }

            if character == "\\" {
                guard nextIndex < expression.endIndex else { return nil }
                let escaped = expression[nextIndex]
                // Alphabetic/numeric escapes may encode classes, boundaries,
                // backreferences, or Unicode/hex code points. Leave those on
                // the ICU path rather than silently changing their meaning.
                guard !escaped.isLetter, !escaped.isNumber else {
                    return nil
                }
                appendWildcardLiteral(escaped, to: &wildcard)
                index = expression.index(after: nextIndex)
                continue
            }

            // Anchors and operators other than the two wildcard quantifiers
            // change regex semantics that the implicit-substring glob cannot
            // represent safely.
            guard !"^$()[]{}|+?*".contains(character) else { return nil }
            appendWildcardLiteral(character, to: &wildcard)
            index = nextIndex
        }

        guard hasWildcardQuantifier else { return nil }
        return BrowserExternalURLWildcardPattern(pattern: wildcard)
    }

    private func appendWildcardLiteral(_ character: Character, to wildcard: inout String) {
        if character == "\\" || character == "*" || character == "?" {
            wildcard.append("\\")
        }
        wildcard.append(character)
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
}
