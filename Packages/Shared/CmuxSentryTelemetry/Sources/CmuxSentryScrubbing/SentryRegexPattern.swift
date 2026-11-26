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

    /// Creates a pattern from a regex literal.
    ///
    /// Force-unwrapping is intentional: the patterns are compile-time constants
    /// authored in this module, so an invalid pattern is a programmer error that
    /// should fail loudly in tests, not silently disable a redaction rule.
    ///
    /// - Parameters:
    ///   - pattern: The ICU regular expression source.
    ///   - options: Matching options. Defaults to `.caseInsensitive`.
    public init(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
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
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for checkingResult in matches.reversed() {
            let match = SentryRegexMatch(source: source, result: checkingResult)
            guard let swiftRange = Range(checkingResult.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement(match))
        }
        return result
    }
}
