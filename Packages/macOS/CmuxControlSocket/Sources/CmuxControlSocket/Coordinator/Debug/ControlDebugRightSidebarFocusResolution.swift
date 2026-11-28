#if DEBUG
/// The outcome of `debug.right_sidebar.focus`, preserving the legacy body's
/// ordering: mode validation first (app-side, against `RightSidebarMode`),
/// then explicit-window lookup, then the reveal attempt.
public enum ControlDebugRightSidebarFocusResolution: Sendable, Equatable {
    /// The mode raw value is not a `RightSidebarMode` (legacy
    /// `invalid_params` / "Invalid right sidebar mode"). Carries the resolved
    /// mode name (the request's, or the `dock` default).
    case invalidMode(String)
    /// No window with the explicitly requested id exists (legacy `not_found`).
    case windowNotFound
    /// The reveal ran; carries the resulting state (all-false when the app
    /// delegate had no sidebar to reveal, matching the legacy `??` defaults).
    case revealed(ControlDebugRightSidebarFocusState)
}
#endif
