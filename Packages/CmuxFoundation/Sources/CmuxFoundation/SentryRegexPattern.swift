public import Foundation

/// A compiled regular expression with a value-typed, capture-aware replacement helper.
///
/// ``SentryRegexPattern`` wraps `NSRegularExpression` so ``SentryScrubber`` can
/// describe its redaction rules as plain data and apply them with a closure
/// that sees each match. The closure receives a ``Match`` exposing the matched
/// text and its capture groups, which lets a rule keep a field prefix (such as
/// `token=`) while redacting only the sensitive value.
public struct SentryRegexPattern: Sendable {
    /// A single regex match handed to a replacement closure.
    public struct Match {
        /// The full text the pattern matched.
        public let value: String
        /// The source string the match was found in (used to resolve capture ranges).
        private let source: NSString
        /// The underlying check result carrying capture-group ranges.
        private let result: NSTextCheckingResult

        /// Creates a match wrapper over an `NSRegularExpression` result.
        fileprivate init(source: NSString, result: NSTextCheckingResult) {
            self.source = source
            self.result = result
            self.value = source.substring(with: result.range)
        }

        /// Returns the substring captured by the given group, or `nil` when the group did not participate.
        ///
        /// - Parameter index: The 1-based capture group index.
        /// - Returns: The captured substring, or `nil`.
        public func captureGroup(_ index: Int) -> String? {
            guard index < result.numberOfRanges else { return nil }
            let range = result.range(at: index)
            guard range.location != NSNotFound, range.length >= 0 else { return nil }
            return source.substring(with: range)
        }
    }

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
    ///   - replacement: A closure returning the replacement for each ``Match``.
    /// - Returns: The rewritten string, or `text` unchanged when nothing matched.
    public func replace(in text: String, with replacement: (Match) -> String) -> String {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for checkingResult in matches.reversed() {
            let match = Match(source: source, result: checkingResult)
            guard let swiftRange = Range(checkingResult.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement(match))
        }
        return result
    }
}
