import CmuxTerminalSizing

/// What a local host applies to the Ghostty surface after a sizing decision.
public enum TerminalSizingApplyTarget: Hashable, Sendable {
    /// The grid is the Mac pane's own grid: remove any cap and fit the pane.
    case uncapped
    /// Pin the surface to this grid (font fitting and letterboxing included).
    case grid(TerminalGridSize)
}
