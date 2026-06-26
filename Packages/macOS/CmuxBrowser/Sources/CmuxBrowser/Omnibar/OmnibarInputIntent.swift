/// How the omnibar interprets the current query text.
///
/// Drives suggestion ranking and Return routing: `urlLike` text resolves to a
/// navigable URL, `queryLike` text is treated as a search, and `ambiguous` text
/// (e.g. a bare `news.`) could be either and is scored between the two.
public enum OmnibarInputIntent: Equatable, Sendable {
    case urlLike
    case queryLike
    case ambiguous
}
