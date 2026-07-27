#if DEBUG
/// The outcome of `debug.type`, preserving the legacy body's two distinct
/// `not_found` failures (no window vs. no first responder).
public enum ControlDebugTypeResolution: Sendable, Equatable {
    /// No candidate window exists (legacy `not_found` / "No window").
    case noWindow
    /// The window has no first responder (legacy `not_found` /
    /// "No first responder").
    case noFirstResponder
    /// The text was inserted at the first responder.
    case inserted
}
#endif
