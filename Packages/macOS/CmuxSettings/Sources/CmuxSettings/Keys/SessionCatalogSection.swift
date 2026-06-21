import Foundation

/// Settings for session restore and per-tab shell history, the `session.*`
/// keys. Both are JSON-backed so they can be edited directly in
/// `~/.config/cmux/cmux.json`.
public struct SessionCatalogSection: SettingCatalogSection {
    /// How a previously saved session is handled on launch: `always`
    /// (restore silently), `ask` (prompt first; the default), or `never`
    /// (start fresh, leaving the session reopenable from the File menu).
    ///
    /// ```json
    /// { "session": { "restoreMode": "ask" } }
    /// ```
    public let restoreMode = JSONKey<SessionRestoreMode>(
        id: "session.restoreMode",
        defaultValue: .ask
    )

    /// Whether each terminal tab keeps its own shell history (up-arrow /
    /// Ctrl-R recall) namespaced by project directory, plus a recorded cmux
    /// command history per tab. When off, tabs use the shell's normal global
    /// history.
    ///
    /// ```json
    /// { "session": { "persistShellHistory": true } }
    /// ```
    public let persistShellHistory = JSONKey<Bool>(
        id: "session.persistShellHistory",
        defaultValue: true
    )

    public init() {}
}
