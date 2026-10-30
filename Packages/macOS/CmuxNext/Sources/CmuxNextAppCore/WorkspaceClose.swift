public import CmuxNextDaemon
public import CmuxNextDaemonService

/// The one close path for workspaces the user closes (close, close others,
/// above, below, sidebar group, palette). A daemon with `batch-close-v1`
/// closes the workspace and ends its terminals in one commit
/// (`close-workspace` with `end_terminals`, which spares a terminal that is
/// kept or shown in another workspace): no reopen exists for a closed
/// workspace, so its terminals need not wait out the reap grace period. A
/// daemon with only `terminal-reap-v1` detaches them and reaps them later;
/// an older daemon gets each shown terminal closed first.
public struct WorkspaceClose {
    public init() {}
    public typealias Terminal = (id: TerminalID, incarnation: TerminalIncarnation?)

    /// Told of every workspace a close path is about to close (the App
    /// releases its remote-terminal tabs' terminals, data-model.md 1.2b).
    @MainActor public static var willClose: ((WorkspaceModel) -> Void)?

    /// Every close path calls this right before closing `workspace`: it
    /// tells `willClose`, and returns the PTY terminals to close before the
    /// workspace, only for a daemon that neither batch-closes nor reaps
    /// detached terminals.
    @MainActor
    public static func closing(_ workspace: WorkspaceModel, on daemon: DaemonService) -> [Terminal] {
        willClose?(workspace)
        guard !daemon.supports(DaemonCapability.batchClose.rawValue), !daemon.supports(DaemonCapability.terminalReap.rawValue) else {
            return []
        }
        return workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            tab.kind == .pty ? tab.terminalID.map { ($0, tab.terminalIncarnation) } : nil
        }
    }

    /// `reason` `.sessionEnd`: a workspace its creator closes again because its first tab did not start, kept out of Recently
    /// Closed (`close-reason-v1`). `ifEmpty`: only while it has no tab (`close-workspace-if-empty-v1`; else `workspace_not_empty`).
    public static func close(_ key: WorkspaceKey, terminals: [Terminal], on connection: DaemonConnection,
                      reason: CloseReason? = nil, ifEmpty: Bool = false) async throws {
        if await connection.supportsBatchClose {
            _ = try await connection.closeWorkspace(key, endTerminals: true, reason: reason, ifEmpty: ifEmpty)
            return
        }
        for terminal in terminals { try? await connection.closeTerminal(terminal.id, incarnation: terminal.incarnation) }
        _ = try await connection.closeWorkspace(key, ifEmpty: ifEmpty)
    }
}
