import CmuxKanbanCore
import Foundation

/// A *live* ``DispatchBackend`` for Kanban cards.
///
/// Unlike ``CmuxNativeBackend``, this backend never spawns or stops the agent
/// itself. The visible agent-session surface owns the single
/// ``AgentSessionProcessStore`` (and therefore the one process); this backend
/// only *observes* that store's events and maps them onto board progress. So a
/// card and its on-screen tab are always the same process — there is no
/// double-spawn.
///
/// The surface is opened on demand (the Kanban "Open live session" action),
/// which registers the shared store + worktree here via
/// ``registerSharedStore(cardId:store:worktreePath:branchName:)`` immediately
/// before the engine calls ``dispatch(card:workingDirectory:)``.
///
/// `@MainActor` because ``AgentSessionProcessStore`` is main-actor isolated; that
/// satisfies `Sendable`, so the `KanbanEngine` actor can hold and call it.
@MainActor
final class CmuxLiveBackend: DispatchBackend {
    /// Per-card setup handed in by the coordinator before ``dispatch``.
    private struct PendingRun {
        let store: AgentSessionProcessStore
        let worktreePath: String
        let branchName: String?
    }

    /// One observed run.
    private final class Run {
        let store: AgentSessionProcessStore
        let token: ObjectIdentifier
        let continuation: AsyncStream<KanbanDispatchProgress>.Continuation

        init(
            store: AgentSessionProcessStore,
            token: ObjectIdentifier,
            continuation: AsyncStream<KanbanDispatchProgress>.Continuation
        ) {
            self.store = store
            self.token = token
            self.continuation = continuation
        }
    }

    private var pending: [UUID: PendingRun] = [:]
    private var runs: [KanbanDispatchHandle: Run] = [:]

    /// Registers the shared process store (and the worktree it runs in) that the
    /// visible surface will own for `cardId`. Call this immediately before
    /// ``KanbanEngine/dispatchLive(cardId:)`` so ``dispatch`` can adopt it.
    func registerSharedStore(
        cardId: UUID,
        store: AgentSessionProcessStore,
        worktreePath: String,
        branchName: String?
    ) {
        pending[cardId] = PendingRun(store: store, worktreePath: worktreePath, branchName: branchName)
    }

    func dispatch(card: KanbanCard, workingDirectory: String?) async throws -> KanbanDispatchSession {
        guard let prepared = pending.removeValue(forKey: card.id) else {
            throw CmuxLiveBackendError.noSharedStore(cardId: card.id)
        }

        let handle = KanbanDispatchHandle(cardId: card.id)
        var continuation: AsyncStream<KanbanDispatchProgress>.Continuation!
        let stream = AsyncStream<KanbanDispatchProgress> { continuation = $0 }
        let token = ObjectIdentifier(self)
        runs[handle] = Run(store: prepared.store, token: token, continuation: continuation)

        // Record the worktree the surface runs in (so the card reflects it and
        // openWorktreeTerminal / orphan reconcile work), then observe the shared
        // store. The surface — not this backend — owns the spawn.
        if !prepared.worktreePath.isEmpty {
            continuation.yield(.provisioned(
                worktreePath: prepared.worktreePath,
                branchName: prepared.branchName ?? ""
            ))
        }
        prepared.store.addEventObserver(token) { [weak self] event in
            self?.handleAgentEvent(event, handle: handle)
        }
        return KanbanDispatchSession(handle: handle, progress: stream)
    }

    func cancel(_ handle: KanbanDispatchHandle) async {
        guard let run = runs[handle] else { return }
        run.store.removeEventObserver(run.token)
        run.continuation.finish()
        runs[handle] = nil
        // DETACH: leave the surface's process and the worktree untouched.
    }

    /// Bridges one raw agent event onto board progress. Mirrors
    /// ``CmuxNativeBackend`` MINUS the one-turn auto-stop: a live session keeps
    /// running across `turnComplete` so the user can keep interacting, and only a
    /// real process exit ends the run.
    func handleAgentEvent(_ event: [String: Any], handle: KanbanDispatchHandle) {
        guard let run = runs[handle] else { return }
        switch event["type"] as? String {
        case "provider.started":
            if let sessionId = event["sessionId"] as? String {
                run.continuation.yield(.started(sessionId: sessionId))
            }
        case "provider.output":
            if let text = event["text"] as? String {
                run.continuation.yield(.output(text))
            }
        case "provider.turnComplete":
            run.continuation.yield(.turnComplete)
        case "provider.exit":
            let rawStatus = (event["status"] as? Int)
                ?? (event["status"] as? Int32).map(Int.init)
                ?? 0
            run.continuation.yield(.exited(status: Int32(clamping: rawStatus)))
            run.continuation.finish()
            run.store.removeEventObserver(run.token)
            runs[handle] = nil
        default:
            break
        }
    }
}

/// Errors thrown by ``CmuxLiveBackend``.
enum CmuxLiveBackendError: Error {
    /// ``CmuxLiveBackend/dispatch(card:workingDirectory:)`` ran without a shared
    /// store registered for the card — the live surface must be prepared first.
    case noSharedStore(cardId: UUID)
}
