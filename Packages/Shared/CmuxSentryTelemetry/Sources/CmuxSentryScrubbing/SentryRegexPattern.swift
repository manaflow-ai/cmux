public import Foundation

/// A compiled regular expression with a value-typed, capture-aware replacement helper.
///
/// ``SentryRegexPattern`` wraps `NSRegularExpression` so ``SentryScrubber`` can
/// describe its redaction rules as plain data and apply them with a closure
/// that sees each match. The closure receives a ``SentryRegexMatch`` exposing
/// the matched text and its capture groups, which lets a rule keep a field
/// prefix (such as `token=`) while redacting only the sensitive value.
public struct SentryRegexPattern: Sendable {
    /// The compiled expression. `NSRegularExpression` is documented thread-safe for matching.
    private let regex: NSRegularExpression
    /// The literal gate: every group holds literals of which any match must contain at least one
    /// (``SentryLiteralProbe``). Empty: the regex always runs.
    private let required: [[[UInt8]]]

    /// Creates a pattern from a regex literal.
    ///
    /// Force-unwrapping is intentional: the patterns are compile-time constants
    /// authored in this module, so an invalid pattern is a programmer error that
    /// should fail loudly in tests, not silently disable a redaction rule.
    ///
    /// - Parameters:
    ///   - pattern: The ICU regular expression source.
    ///   - options: Matching options. Defaults to `.caseInsensitive`.
    ///   - requires: Groups of lowercase ASCII literals: every match contains at least one literal of
    ///     each group, ignoring ASCII case. A text without them skips the regex
    ///     (``replace(in:probe:with:)``). A literal no match must contain would skip a real match, so
    ///     list only literals the pattern spells out; `SentryLiteralGateTests` checks the gate against
    ///     the ungated rules.
    public init(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive], requires: [[String]] = []) {
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
        self.required = requires.map { group in
            group.map { literal in
                assert(!literal.isEmpty && literal.utf8.allSatisfy { $0 < 0x80 && !($0 >= 0x41 && $0 <= 0x5A) },
                       "SentryRegexPattern: a required literal is empty, non-ASCII or uppercase: \(literal)")
                return Array(literal.utf8)
            }
        }
    }

    /// Whether the text `probe` was made from may hold a match: false only when a group of the
    /// pattern's required literals is wholly absent from it.
    func mayMatch(_ probe: SentryLiteralProbe) -> Bool {
        required.allSatisfy { group in group.contains { probe.mayContain($0) } }
    }

    /// ``replace(in:with:)`` behind the literal gate: nil, with no regex run, when `probe` (made from
    /// `text`) rules every match out, or when nothing matched; else the rewritten text.
    func replace(in text: String, probe: SentryLiteralProbe, with replacement: (SentryRegexMatch) -> String) -> String? {
        guard mayMatch(probe) else { return nil }
        return replaceMatches(in: text, with: replacement)
    }

    /// Replaces every match with the string returned by `replacement`.
    ///
    /// Matches are rewritten from the end backwards so earlier ranges stay valid
    /// while later matches are spliced out.
    ///
    /// - Parameters:
    ///   - text: The string to scan.
    ///   - replacement: A closure returning the replacement for each ``SentryRegexMatch``.
    /// - Returns: The rewritten string, or `text` unchanged when nothing matched.
    public func replace(in text: String, with replacement: (SentryRegexMatch) -> String) -> String {
        replaceMatches(in: text, with: replacement) ?? text
    }

    /// The rewritten text, or nil when nothing matched.
    private func replaceMatches(in text: String, with replacement: (SentryRegexMatch) -> String) -> String? {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return nil }

        var result = text
        for checkingResult in matches.reversed() {
            let match = SentryRegexMatch(source: source, result: checkingResult)
            guard let swiftRange = Range(checkingResult.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement(match))
        }
        return result
    }
}
