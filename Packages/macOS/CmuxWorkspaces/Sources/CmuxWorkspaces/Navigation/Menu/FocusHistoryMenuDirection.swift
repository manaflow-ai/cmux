/// Which side of the focus-history stack a menu enumerates.
public enum FocusHistoryMenuDirection: Equatable, Sendable {
    /// Entries older than the current position (the back stack).
    case back
    /// Entries newer than the current position (the forward stack).
    case forward
}
