/// Layer responsible for painting a terminal surface background.
public enum TerminalSurfaceBackgroundFillOwner: Equatable, Sendable {
    /// The terminal hosting view should paint the resolved background color.
    case surfaceHostLayer

    /// The shared root backdrop should remain the only visible background fill.
    case sharedWindowBackdrop

    /// The Bonsplit pane backdrop should remain the only visible background fill.
    case bonsplitPaneBackdrop

    /// Ghostty's renderer owns the background instead of cmux host layers.
    case ghosttyNativeRenderer
}
