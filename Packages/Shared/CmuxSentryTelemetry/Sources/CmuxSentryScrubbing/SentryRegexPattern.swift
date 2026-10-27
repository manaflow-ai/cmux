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
    /// The result is built in one forward pass over the source's UTF-16 ranges
    /// (the text between matches, then each replacement), so the time is linear
    /// in the text however many matches it holds (p10-stability-191).
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

        var result = ""
        result.reserveCapacity(text.utf8.count)
        var copied = 0
        for checkingResult in matches {
            let range = checkingResult.range
            result += source.substring(with: NSRange(location: copied, length: range.location - copied))
            result += replacement(SentryRegexMatch(source: source, result: checkingResult))
            copied = NSMaxRange(range)
        }
        result += source.substring(from: copied)
        return result
    }

    /// The UTF-16 ranges of every match in `text`, in order.
    func matchRanges(in text: String) -> [NSRange] {
        regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range)
    }
}
