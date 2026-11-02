public import CmuxNextDaemon
import CmuxNextWakeups

extension DaemonService {
    /// `workspace.create` with a first terminal (an incognito window's) on `connection`, answered by the daemon: it
    /// waits through late replies under one idempotency key (`StateResourceClient.createWorkspace`), never on the 2 s
    /// client deadline. A busy daemon still makes the workspace it answers late, and a create that gave up first left
    /// that workspace to open as a stray window with a terminal (#30965). Its safety net is ``createReplyBound`` for a
    /// daemon that keeps its socket open and never answers: past it this returns nil, and the caller decides from the
    /// store, which lists the workspace if the daemon made it. Cancelling the caller cancels the create.
    public func createWorkspaceAwaitingReply(on connection: DaemonConnection, ephemeral: Bool,
                                             focus: Bool) async throws -> StateResourceClient.CreatedWorkspace? {
        // task-owner: the create; the bound below or the caller's cancellation cancels it, and this call awaits it
        let create = Task { try await connection.state.createWorkspace(name: nil, ephemeral: ephemeral, terminal: true, focus: focus) }
        let bound = DemandTimer(owner: "DaemonService.createReplyBound")
        defer { bound.cancel() }
        bound.schedule(after: createReplyBound) { create.cancel() }
        do {
            return try await withTaskCancellationHandler { try await create.value } onCancel: { create.cancel() }
        } catch is CancellationError where !Task.isCancelled {
            return nil
        }
    }

    /// The workspace ``createWorkspaceAwaitingReply(on:ephemeral:focus:)`` made, with its first terminal tab: the
    /// reply's, once the store has applied it. Past the bound with no answer, the store as it is now decides: the
    /// workspace among `placed()` (the ids placement gave the caller's waiting window) that it lists on the same
    /// connection with the asked `ephemeral` flag, which the daemon made meanwhile. When it lists none (or the
    /// connection changed) this throws ``WorkspaceCreateUnanswered``. Nil: the reply's workspace or tab is not listed.
    public func createdWorkspace(on connection: DaemonConnection, ephemeral: Bool, focus: Bool,
                                 placed: () -> [String]) async throws -> (workspace: WorkspaceModel, tab: TabModel)? {
        guard let created = try await createWorkspaceAwaitingReply(on: connection, ephemeral: ephemeral, focus: focus) else {
            let workspace = placed().lazy.compactMap { self.store.workspace(id: $0) }.first { ($0.ephemeral == true) == ephemeral }
            guard self.connection === connection, let workspace else { throw WorkspaceCreateUnanswered() }
            return workspace.screens.flatMap(\.panes).lazy.flatMap(\.tabs).first { $0.kind == .pty }.map { (workspace, $0) }
        }
        await appliedThroughReply(on: connection, after: "create workspace")
        guard let workspace = store.workspace(resourceID: created.workspaceID) else { return nil }
        return workspace.screens.flatMap(\.panes).lazy.flatMap(\.tabs).first { $0.resourceID == created.tabID }.map { (workspace, $0) }
    }
}

/// A create with a first terminal whose daemon did not answer within ``DaemonService/createReplyBound`` and whose
/// store lists no workspace it made: nothing opens, and the caller tells the person.
public struct WorkspaceCreateUnanswered: Error, Sendable {
    public init() {}
}
