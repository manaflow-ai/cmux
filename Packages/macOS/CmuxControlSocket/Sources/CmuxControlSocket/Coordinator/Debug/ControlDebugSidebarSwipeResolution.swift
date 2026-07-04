#if DEBUG
/// The outcome of `debug.sidebar.simulate_swipe`.
public enum ControlDebugSidebarSwipeResolution: Sendable, Equatable {
    /// The requested workspace row is not currently registered in the visible
    /// sidebar swipe registry.
    case rowNotRegistered
    /// The synthetic sequence was delivered to the row's swipe capture view.
    ///
    /// - Parameters:
    ///   - committed: Whether the sequence produced a real swipe commit.
    ///   - offset: The row offset left visible after the sequence.
    ///   - released: Whether the sequence ended or cancelled the gesture.
    case simulated(committed: Bool, offset: Double, released: Bool)
}
#endif
