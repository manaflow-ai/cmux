/// The two AppKit scrollbar styles that differ in whether they reserve layout space.
public enum TerminalScrollerStyle: Equatable, Sendable {
    /// The classic scrollbar reserves a fixed trailing gutter in the terminal grid.
    case legacy

    /// The overlay scrollbar draws over content and reserves no layout space.
    case overlay
}

extension TerminalScrollerStyle {
    /// The global defaults key that stores the "Show scroll bars" preference.
    public static let showScrollBarsDefaultsKey = "AppleShowScrollBars"

    /// The style for a stored "Show scroll bars" value.
    ///
    /// Only an explicit "Always" selects the legacy scroller, which reserves a
    /// permanent gutter beside the grid (https://github.com/manaflow-ai/cmux/issues/9994).
    /// "Automatic" and "When scrolling" use the overlay scroller, as upstream
    /// Ghostty does. AppKit resolves "Automatic" to legacy when a mouse is the
    /// only pointing device, which put an empty gutter on every pane of a
    /// desktop Mac without a trackpad.
    ///
    /// - Parameter showScrollBarsPreference: The `AppleShowScrollBars` value,
    ///   or nil when the preference is unset (macOS treats that as Automatic).
    public init(showScrollBarsPreference: String?) {
        self = showScrollBarsPreference == "Always" ? .legacy : .overlay
    }
}
