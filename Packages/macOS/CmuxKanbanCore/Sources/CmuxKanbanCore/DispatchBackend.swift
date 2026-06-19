/// Runs a single Kanban card's task, whatever "running" means for that backend.
///
/// Implementations are the seam between the engine's board policy and the
/// outside world: the native `cmux` backend spawns an agent process per card;
/// future `cnvs`/`hermes` backends proxy to an external agent gateway. A
/// backend reports raw lifecycle facts via ``KanbanDispatchProgress`` and never
/// touches board state — ``KanbanEngine`` owns every column transition.
///
/// Conformers are `Sendable` so the engine actor can hold and call one across
/// isolation domains. The native backend is `@MainActor` (it drives a
/// main-thread `AgentSessionProcessStore`), which satisfies `Sendable`.
public protocol DispatchBackend: Sendable {
    /// Starts running `card`, optionally inside `workingDirectory`.
    ///
    /// - Returns: a ``KanbanDispatchSession`` whose `progress` stream the engine
    ///   consumes until it finishes.
    /// - Throws: if the run cannot be started at all (e.g. the agent executable
    ///   cannot be resolved). A failure *after* start is reported as
    ///   ``KanbanDispatchProgress/failed(message:)`` on the stream instead.
    func dispatch(card: KanbanCard, workingDirectory: String?) async throws -> KanbanDispatchSession

    /// Cancels the run identified by `handle`, terminating any process and
    /// finishing its progress stream. A no-op if the run already ended.
    func cancel(_ handle: KanbanDispatchHandle) async
}
