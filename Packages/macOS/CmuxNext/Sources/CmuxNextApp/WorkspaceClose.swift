import CmuxNextDaemon

/// The one close path for workspaces the user closes (close, close others,
/// above, below, sidebar group, palette). A daemon with `batch-close-v1`
/// closes the workspace and ends its terminals in one commit
/// (`close-workspace` with `end_terminals`, which spares a terminal that is
/// kept or shown in another workspace): no reopen exists for a closed
/// workspace, so its terminals need not wait out the reap grace period. A
/// daemon with only `terminal-reap-v1` detaches them and reaps them later;
/// an older daemon gets each shown terminal closed first.
enum WorkspaceClose {
    typealias Terminal = (id: TerminalID, incarnation: TerminalIncarnation?)

    /// The PTY terminals to close before the workspace: only for a daemon
    /// that neither batch-closes nor reaps detached terminals.
    @MainActor
    static func terminals(of workspace: WorkspaceModel, on daemon: DaemonService) -> [Terminal] {
        guard !daemon.supports(DaemonCapabilities.batchClose), !daemon.supports(DaemonCapabilities.terminalReap) else {
            return []
        }
        return workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            tab.kind == .pty ? tab.terminalID.map { ($0, tab.terminalIncarnation) } : nil
        }
    }

    static func close(_ key: WorkspaceKey, terminals: [Terminal], on connection: DaemonConnection) async throws {
        if await connection.supportsBatchClose {
            _ = try await connection.closeWorkspace(key, endTerminals: true)
            return
        }
        for terminal in terminals { try? await connection.closeTerminal(terminal.id, incarnation: terminal.incarnation) }
        _ = try await connection.closeWorkspace(key)
    }
}
