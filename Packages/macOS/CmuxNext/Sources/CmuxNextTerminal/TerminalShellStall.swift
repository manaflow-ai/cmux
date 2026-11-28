/// Why a terminal's shell does not answer while the view's own link is up:
/// the daemon reports the shell's host link down (tab `terminal_state`).
/// The view keeps the last screen, often a lone cursor, and keys go nowhere,
/// so the banner says so instead.
public nonisolated enum TerminalShellStall: Sendable, Equatable {
    /// The daemon is reconnecting to (or adopting) the shell's host.
    case reconnecting
    /// The daemon gave up reconnecting; the shell may still run unreached.
    case linkLost
    /// Another cmux build's host owns the shell; this daemon cannot adopt it.
    case otherBuild
}
