/// Controls sizing behavior for a standalone Settings window or an embedded pane.
public enum SettingsPresentationStyle: Sendable {
    /// Preserve the standalone window's minimum content size.
    case window
    /// Adapt to the size of the containing workspace pane.
    case pane
}
