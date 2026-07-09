internal import Foundation

/// The validated `mode` of `browser.focus_mode.set`. The coordinator parses and
/// validates the raw string (`enter`/`on`/`true`/`active` → ``enter``,
/// `exit`/`off`/`false`/`inactive` → ``exit``, `toggle` → ``toggle``) and the
/// witness applies it. The raw mode string is preserved for the `mode` payload
/// echo.
public enum ControlBrowserFocusModeIntent: Sendable, Equatable {
    /// Engage browser focus mode (also focuses the web view).
    case enter
    /// Disengage browser focus mode.
    case exit
    /// Toggle browser focus mode.
    case toggle
}
