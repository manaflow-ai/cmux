public import CmuxNextActions
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
    /// A workspace the daemon no longer has counts as closed (`isAlreadyClosed`).
    ///
    /// The close ends when the daemon answers it (its reply or refusal) or the connection ends, never on the 2 s client
    /// deadline (`DaemonConnection.closeWorkspaceAwaitingReply`): a busy daemon commits a close it answers late, and a
    /// close that gave up first listed the row again as refused and left it out of Undo. Its safety net is a bound
    /// (`DaemonService.closeReplyBound`, 60 s) for a daemon that keeps its socket open and never answers: past it the
    /// store of `daemon` decides (``unanswered(_:on:)``), not the timeout. `waitsForReply` false keeps the control
    /// deadline for a caller that must end on time and ignores the outcome (quit's incognito closes).
    public static func close(_ key: WorkspaceKey, terminals: [Terminal], on connection: DaemonConnection, reason: CloseReason? = nil,
                             ifEmpty: Bool = false, waitsForReply: Bool = true, decidedBy daemon: DaemonService? = nil) async throws {
        let bound: Duration? = waitsForReply ? await daemon?.closeReplyBound ?? DaemonConnection.closeReplyBound : nil
        do {
            if await connection.supportsBatchClose {
                if let bound {
                    _ = try await connection.closeWorkspaceAwaitingReply(key, endTerminals: true, reason: reason, ifEmpty: ifEmpty, within: bound)
                } else {
                    _ = try await connection.closeWorkspace(key, endTerminals: true, reason: reason, ifEmpty: ifEmpty)
                }
                return
            }
            for terminal in terminals { try? await connection.closeTerminal(terminal.id, incarnation: terminal.incarnation) }
            if let bound {
                _ = try await connection.closeWorkspaceAwaitingReply(key, ifEmpty: ifEmpty, within: bound)
            } else {
                _ = try await connection.closeWorkspace(key, ifEmpty: ifEmpty)
            }
        } catch where isAlreadyClosed(error) {
            return
        } catch DaemonError.timedOut(_) where bound != nil {
            try await unanswered([key], on: daemon)
        }
    }

    /// A close whose daemon did not answer within its bound, decided from the store and not from the timeout: it went
    /// through when the store of `daemon` lists none of `keys` (the close's events came, its reply did not). Else it
    /// throws the reason (`RefusalStrings.closeUnanswered`), and the caller lists the rows again with it. With no store
    /// to read, it is the reason too.
    public static func unanswered(_ keys: [WorkspaceKey], on daemon: DaemonService?) async throws {
        if let daemon, await !lists(keys, on: daemon) { return }
        throw ActionFailure(message: RefusalStrings.closeUnanswered)
    }

    @MainActor private static func lists(_ keys: [WorkspaceKey], on daemon: DaemonService) -> Bool {
        daemon.store.workspaces.contains { $0.key.map(keys.contains) ?? false }
    }

    /// What a close's toast says for `failure`: the reason of a typed refusal (the machine did not answer), else nil
    /// (the generic "could not be closed").
    public static func shownReason(_ failure: ActionWorkFailure?) -> String? {
        failure?.refusal == nil ? nil : failure?.message
    }

    /// Whether `error` is the daemon saying the workspace is already gone: closed before this request came
    /// ("unknown workspace ..."), or by another close that committed while this one was on its way ("close
    /// target disappeared"). A close asks for the workspace to be gone, so either is a close that went through,
    /// never a refusal (Leo 2026-10-31, a sidebar close of 8 rows showed "The workspace could not be closed."
    /// above "Closed 8 workspaces": "plus the dumb shit when it apparently races a delete"). A refusal (for
    /// example `workspace_not_empty`) has a code or another message and still fails.
    public static func isAlreadyClosed(_ error: any Error) -> Bool {
        guard case let DaemonError.command(cmd, message, code, _, _) = error, cmd == CloseWorkspaceRequest.command, code == nil
        else { return false }
        return message.hasPrefix("unknown workspace") || message == "close target disappeared"
    }
}
