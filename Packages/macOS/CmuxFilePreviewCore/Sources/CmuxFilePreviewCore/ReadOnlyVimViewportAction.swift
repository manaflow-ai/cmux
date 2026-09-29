/// A viewport operation requested by read-only Vim navigation.
public enum ReadOnlyVimViewportAction: Equatable {
    /// Moves the cursor by the given number of visible pages.
    case page(Double)
    /// Moves to the top, middle, or bottom visible line (0, 0.5, or 1).
    case visibleLine(Double)
    /// Aligns the cursor's line with the top, middle, or bottom of the viewport.
    case align(Double)
}
