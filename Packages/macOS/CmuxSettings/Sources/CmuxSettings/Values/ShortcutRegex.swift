import Foundation

/// A compiled, `Sendable` regular expression used by the `=~` operator in a
/// ``ShortcutWhenClause``.
///
/// Wraps `NSRegularExpression` and keeps the source pattern so two values compare
/// equal when their patterns are equal. Construction fails (`init?` returns `nil`)
/// when the pattern does not compile, which lets ``ShortcutWhenClause/parse(_:)``
/// reject a malformed `/.../` literal.
public struct ShortcutRegex: Sendable, Equatable {
    /// The original pattern source, as written between the `/.../` delimiters.
    public let pattern: String

    private let regularExpression: NSRegularExpression

    /// Creates a regex from a pattern, returning `nil` when it does not compile.
    ///
    /// - Parameter pattern: The regular-expression source, without `/` delimiters.
    public init?(pattern: String) {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        self.pattern = pattern
        self.regularExpression = regularExpression
    }

    /// Whether the pattern matches anywhere within `string`.
    ///
    /// - Parameter string: The candidate string (typically a context key's string value).
    /// - Returns: `true` when the pattern matches at least once.
    public func matches(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regularExpression.firstMatch(in: string, range: range) != nil
    }

    /// Two regexes are equal when their source patterns are equal.
    public static func == (lhs: ShortcutRegex, rhs: ShortcutRegex) -> Bool {
        lhs.pattern == rhs.pattern
    }
}
