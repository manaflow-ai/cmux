/// Ghostty's `window-`, `tab-` and `split-inherit-working-directory` keys.
///
/// When a key is false, a new terminal of that kind starts in the configured
/// `working-directory` instead of the focused terminal's directory (#177).
public struct GhosttyWorkingDirectoryInheritance: Sendable, Equatable {
    /// New workspaces inherit the focused terminal's directory.
    public var window: Bool
    /// New terminal tabs in a pane inherit the selected terminal's directory.
    public var tab: Bool
    /// New splits inherit the source terminal's directory.
    public var split: Bool

    /// Creates an inheritance setting; Ghostty's defaults inherit everywhere.
    public init(window: Bool = true, tab: Bool = true, split: Bool = true) {
        self.window = window
        self.tab = tab
        self.split = split
    }
}
