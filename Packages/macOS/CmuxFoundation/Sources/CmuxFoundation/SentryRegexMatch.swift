internal import Foundation

/// A single regular-expression match handed to a ``SentryRegexPattern`` replacement closure.
///
/// Exposes the matched text and its capture groups so a redaction rule can keep
/// a field prefix (such as `token=`) while redacting only the sensitive value.
public struct SentryRegexMatch {
    /// The full text the pattern matched.
    public let value: String
    /// The source string the match was found in (used to resolve capture ranges).
    private let source: NSString
    /// The underlying check result carrying capture-group ranges.
    private let result: NSTextCheckingResult

    /// Creates a match wrapper over an `NSRegularExpression` result.
    ///
    /// - Parameters:
    ///   - source: The string the expression was matched against.
    ///   - result: The `NSTextCheckingResult` describing the match and its capture ranges.
    init(source: NSString, result: NSTextCheckingResult) {
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
