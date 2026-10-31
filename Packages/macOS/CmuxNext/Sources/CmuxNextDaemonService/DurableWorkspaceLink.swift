public import CmuxNextActions
import CmuxNextDaemon

/// Reopens the closed workspace a `cmux://workspace/ws_…` link names and reveals it.
/// The daemon recreates it with a new workspace id (durable-links a343 will preserve ids).
/// Navigation and refusal presentation are supplied by the caller.
@MainActor
public struct DurableWorkspaceLink {
    private let daemons: [DaemonService]
    private let reveal: @MainActor (String) -> Bool
    private let refuse: @MainActor () -> Void

    /// Creates a link resolver over the connected machines, local first.
    /// `reveal` shows a workspace by its store key; `refuse` presents the gone refusal.
    public init(daemons: [DaemonService], reveal: @escaping @MainActor (String) -> Bool,
                refuse: @escaping @MainActor () -> Void) {
        self.daemons = daemons.filter { $0.connection != nil }
        self.reveal = reveal
        self.refuse = refuse
    }

    /// Asks each daemon until one reopens `id`, waits for its store, then reveals it.
    /// A failure other than not-found stops the walk, since it may have applied.
    public func open(_ id: String) async -> ActionWorkFailure? {
        for daemon in daemons {
            guard let connection = daemon.connection else { continue }
            do {
                let item = try await connection.state.reopenClosed(workspace: id)
                await daemon.appliedThroughReply(on: connection, after: "reopen linked workspace")
                if let workspace = item.workspaceID,
                   let key = await daemon.store.workspace(afterReopen: workspace, clock: daemon.reopenClock),
                   reveal(key) {
                    return nil
                }
                return ActionWorkFailure(RefusalStrings.linkTargetGone, mayHaveApplied: true)
            } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                continue
            } catch {
                daemon.logger.error("closed.reopen {workspace} failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("closed.reopen: \(error)", mayHaveApplied: true)
            }
        }
        refuse()
        return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
    }
}
