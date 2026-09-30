/// How the Mac produced a task provider's model list.
public enum MobileTaskModelListSource: String, Equatable, Sendable {
    /// A provider command returned an authoritative dynamic list.
    case discovered
    /// The over-the-air cmux catalog supplied the list.
    case backend
    /// A legacy host prepended its configured default to its built-in list.
    case augmented
    /// Agent discovery was unavailable and returned no values.
    case fallback
}
