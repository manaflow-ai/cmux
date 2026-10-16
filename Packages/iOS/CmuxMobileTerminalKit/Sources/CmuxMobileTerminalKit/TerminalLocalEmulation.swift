/// Who answers terminal queries for a surface, and therefore which bytes the
/// phone's own emulator may send back toward the PTY.
public enum TerminalLocalEmulation: Sendable, Equatable {
    /// A paired Mac is the terminal; everything the local mirror writes is
    /// spurious and dropped.
    case mirror
    /// The phone is the only emulator (SSH plain/tmux): replies, mouse,
    /// focus, and scroll bytes all go to the PTY.
    case authoritative
    /// A server-side emulator answers queries (SSH cmux-tui). Query replies
    /// are dropped so the program never sees two answers; user-driven
    /// reports (mouse, focus, alternate-scroll arrows) still go through.
    case inputOnly
}
