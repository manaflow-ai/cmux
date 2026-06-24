/// Which color slot of a ``FeedButton`` the debug style path is resolving.
///
/// Used only by the `#if DEBUG` style-exploration path: the app-side debug
/// settings repository maps a `(FeedButton.Kind, FeedButtonColorRole,
/// ColorScheme)` triple to an optional override color, surfaced to the package
/// through ``FeedButtonDebugStyle/color``.
public enum FeedButtonColorRole: String, Sendable {
    /// The resting background fill.
    case background
    /// The background fill while the pointer is over the button.
    case hoverBackground
    /// The label/icon tint.
    case foreground
}
