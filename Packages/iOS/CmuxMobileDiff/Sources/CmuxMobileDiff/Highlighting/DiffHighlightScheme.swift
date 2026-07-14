/// Color appearance used as part of the syntax-highlight cache key.
enum DiffHighlightScheme: String, Sendable, Equatable, Hashable {
    /// GitHub's light syntax theme.
    case light
    /// GitHub's dark syntax theme.
    case dark
}
