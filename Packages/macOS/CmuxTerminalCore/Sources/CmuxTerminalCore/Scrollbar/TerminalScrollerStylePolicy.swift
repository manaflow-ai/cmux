/// Chooses the terminal scroller style from the macOS "Show scroll bars" preference.
///
/// Only an explicit "Always" selects the legacy scroller, which reserves a
/// permanent gutter beside the grid (https://github.com/manaflow-ai/cmux/issues/9994).
/// "Automatic" and "When scrolling" use the overlay scroller, as upstream
/// Ghostty does. AppKit resolves "Automatic" to legacy whenever a mouse is
/// connected, which put an empty gutter on every pane of a desktop Mac.
public enum TerminalScrollerStylePolicy {
    /// The global defaults key that stores the "Show scroll bars" preference.
    public static let showScrollBarsDefaultsKey = "AppleShowScrollBars"

    /// Returns the scroller style for a stored "Show scroll bars" value.
    ///
    /// - Parameter showScrollBarsPreference: The `AppleShowScrollBars` value,
    ///   or nil when the preference is unset (macOS treats that as Automatic).
    public static func style(showScrollBarsPreference: String?) -> TerminalScrollerStyle {
        showScrollBarsPreference == "Always" ? .legacy : .overlay
    }
}
