/// Semantic highlight.js token role used to paint a ``TokenPalette``.
public enum TokenRole: Sendable, Equatable, Hashable {
    /// Default / unsubstituted text.
    case foreground
    /// Comments and quotes.
    case comment
    /// Keywords, tags, literals (`true`, `func`, JSX tags).
    case keyword
    /// Types, class names, builtins.
    case type
    /// String literals.
    case string
    /// Numbers, symbols, titles.
    case number
    /// Attributes, JSON keys, selectors.
    case attribute
    /// Variables and template variables.
    case variable
    /// Regular expressions and links.
    case regexp
}
