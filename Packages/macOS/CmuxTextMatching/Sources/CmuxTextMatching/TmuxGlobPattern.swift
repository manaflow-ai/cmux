/// A shell glob matched the way tmux matches `find-window` patterns, with `fnmatch(3)`.
public struct TmuxGlobPattern: Sendable {
    /// Compiles `pattern`.
    public init(_ pattern: String, caseInsensitive: Bool) {}
    /// Whether the pattern matches all of `text`.
    public func matchesWhole(_ text: String) -> Bool { false }
    /// The leftmost span of `text` the pattern matches.
    public func firstMatch(in text: String) -> Range<String.Index>? { nil }
}
