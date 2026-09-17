/// How the Mac produced a task provider's model list.
public enum MobileTaskModelListSource: String, Equatable, Sendable {
    /// A provider command returned an authoritative dynamic list.
    case discovered
    /// A configured default was prepended to the curated list.
    case augmented
    /// Discovery was unavailable, so the curated list was returned.
    case fallback
}
