/// The `TERM` a new cmux terminal starts with (`terminal.term` in cmux.json, ``TerminalTermSetting``).
///
/// `xterm-256color` is the default: every Mac, Linux host, VM and container has
/// its terminfo entry, so `ssh host htop` works with nothing installed there.
/// `xterm-ghostty` names Ghostty's own entry, which most remote hosts lack.
public nonisolated enum TerminalTerm: String, CaseIterable, Sendable {
    /// The standard entry every host has (the default).
    case xterm256color = "xterm-256color"
    /// Ghostty's own entry; used only when it is installed on this Mac.
    case xtermGhostty = "xterm-ghostty"
}
