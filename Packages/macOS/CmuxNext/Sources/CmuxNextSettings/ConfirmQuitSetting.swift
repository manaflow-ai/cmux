/// `app.confirmQuit` (Lawrence 2026-11-10: one accidental Cmd-Q ended every
/// agent and terminal with no question). On when unset or invalid; the
/// question's "Don't ask again" turns it off.
nonisolated extension CmuxConfigSnapshot {
    /// `app.confirmQuit`.
    public var confirmQuit: Bool { root.value(at: Self.confirmQuitPath)?.boolValue ?? Self.confirmQuitDefault }
}

/// `app.warnBeforeQuitShortcut` (https://github.com/manaflow-ai/cmux/issues/48621): the first
/// Cmd-Q warns, and holding it or pressing it again quits. On when unset or invalid.
nonisolated extension CmuxConfigSnapshot {
    /// `app.warnBeforeQuitShortcut`.
    public var warnBeforeQuitShortcut: Bool {
        root.value(at: Self.warnBeforeQuitShortcutPath)?.boolValue ?? Self.warnBeforeQuitShortcutDefault
    }
}
