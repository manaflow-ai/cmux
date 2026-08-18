/// A display classification for one highlighted source span.
public enum FilePreviewSyntaxTokenKind: CaseIterable, Equatable, Hashable, Sendable {
    /// A language keyword such as `let`, `SELECT`, or `return`.
    case keyword
    /// A built-in or standard-library type name.
    case type
    /// A quoted string or character literal.
    case string
    /// A numeric literal.
    case number
    /// A line or block comment.
    case comment
    /// An identifier followed by a call parenthesis.
    case function
    /// An annotation, decorator, or preprocessor directive.
    case attribute
}
