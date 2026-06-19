/// The result of starting a dispatch: a ``KanbanDispatchHandle`` plus the
/// stream of ``KanbanDispatchProgress`` events the run produces.
///
/// ``KanbanEngine`` is the sole consumer of ``progress``; it applies each event
/// to the board and re-publishes it for the UI. The stream finishes when the
/// run ends (a terminal ``KanbanDispatchProgress/exited(status:)`` or
/// ``KanbanDispatchProgress/failed(message:)``, then the producer finishes the
/// stream).
public struct KanbanDispatchSession: Sendable {
    public let handle: KanbanDispatchHandle
    public let progress: AsyncStream<KanbanDispatchProgress>

    public init(handle: KanbanDispatchHandle, progress: AsyncStream<KanbanDispatchProgress>) {
        self.handle = handle
        self.progress = progress
    }
}
