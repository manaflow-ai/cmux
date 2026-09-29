import CmuxNextDaemon

/// The one close path for workspaces the user closes (close, close others,
/// above, below, group, palette). A workspace closes together with its
/// terminals: a daemon with `batch-close-v1` does it in one commit
/// (`close-workspace` with `end_terminals`, which spares a terminal that is
/// kept or shown in another workspace); an older daemon gets each shown
/// terminal closed first, then the workspace.
enum WorkspaceClose {
    typealias Terminal = (id: TerminalID, incarnation: TerminalIncarnation?)

    /// The PTY terminals `workspace` shows, captured on the main actor for
    /// the fallback path.
    @MainActor
    static func terminals(of workspace: WorkspaceModel) -> [Terminal] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
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
