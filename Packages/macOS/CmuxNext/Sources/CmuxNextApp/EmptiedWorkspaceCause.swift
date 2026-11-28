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

extension EmptiedWorkspaceCause {
    /// The cause from the daemon's terminal registry: the workspace's most
    /// recently ended terminal decides. A process end (exit, signal) is a
    /// closed tab; an unobserved end (outcome `unknown`) is a lost terminal.
    /// With no ended terminal on record the tab was closed by a client.
    static func from(_ terminals: [TerminalRegistryEntry], workspace key: WorkspaceKey) -> EmptiedWorkspaceCause {
        let ended = terminals.filter { $0.workspaceKey == key.rawValue }.compactMap(\.exit)
        guard let last = ended.max(by: { $0.exitedAtMs < $1.exitedAtMs }) else { return .tabClosed }
        return last.outcomeKind == "unknown" ? .terminalLost : .tabClosed
    }
}
