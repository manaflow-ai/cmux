/// The validated `browser.focus_mode.set` action, after the coordinator maps
/// the legacy mode aliases (`enter/on/true/active`, `exit/off/false/inactive`,
/// `toggle`).
public enum ControlBrowserFocusModeAction: Sendable, Equatable {
    /// One of the enter aliases.
    case activate
    /// One of the exit aliases.
    case deactivate
    /// `toggle`.
    case toggle
}
