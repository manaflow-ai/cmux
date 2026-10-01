import CmuxNextDaemon

/// Why a workspace this connection saw with a pane has none now.
enum EmptiedWorkspaceCause: Equatable {
    /// Its last tab was closed or its last process ended (exit or signal):
    /// the workspace closes (dogfood nxdog9).
    case tabClosed
    /// Its last terminal was lost, not ended: the daemon found the terminal
    /// host already dead when it adopted it (a crash, a kill, a reboot;
    /// `TerminalExit` outcome `unknown`). The workspace is the user's
    /// layout and name, so it stays and gets a new terminal.
    case terminalLost
}
