import CmuxKanbanCore
import Foundation

/// The native ``DispatchBackend``: runs each Kanban card as a local agent
/// process via an ``AgentSessionProcessStore``, one store per run (the store
/// enforces a single session, so cards cannot share one).
///
/// `@MainActor` because `AgentSessionProcessStore` is main-actor isolated; that
/// satisfies `Sendable`, so the `KanbanEngine` actor can hold it across
/// isolation. The store's push-based `eventSink` (`[String: Any]` dictionaries)
/// is bridged onto the engine-facing ``KanbanDispatchProgress`` stream here — the
/// engine never sees the raw agent event shape.
@MainActor
final class CmuxNativeBackend: DispatchBackend {
    /// One live run's state, confined to `@MainActor`.
    private final class Run {
        let store: AgentSessionProcessStore
        let continuation: AsyncStream<KanbanDispatchProgress>.Continuation
        var sessionId: String?

        init(store: AgentSessionProcessStore, continuation: AsyncStream<KanbanDispatchProgress>.Continuation) {
            self.store = store
            self.continuation = continuation
        }
    }

    /// Repository root the workspace lives in; the base for per-card worktrees
    /// and the fallback working directory.
    private let workspaceRoot: String?
    private let worktreeProvisioner: GitWorktreeProvisioner?
    private var runs: [KanbanDispatchHandle: Run] = [:]

    init(workspaceRoot: String?, worktreeProvisioner: GitWorktreeProvisioner? = nil) {
        self.workspaceRoot = workspaceRoot
        self.worktreeProvisioner = worktreeProvisioner
    }

    func dispatch(card: KanbanCard, workingDirectory: String?) async throws -> KanbanDispatchSession {
        let provider = AgentSessionProviderID(rawValue: card.agentProvider ?? AgentSessionProviderID.claude.rawValue)
            ?? .claude
        let configuredPaths = AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        let plan = try await Task.detached(priority: .userInitiated) {
            try AgentExecutableResolver(configuredExecutablePaths: configuredPaths).resolve(provider)
        }.value

        let handle = KanbanDispatchHandle(cardId: card.id)
        var continuation: AsyncStream<KanbanDispatchProgress>.Continuation!
        let stream = AsyncStream<KanbanDispatchProgress> { continuation = $0 }
        let store = AgentSessionProcessStore()
        let run = Run(store: store, continuation: continuation)
        runs[handle] = run
        store.eventSink = { [weak self] event in
            self?.handleAgentEvent(event, handle: handle)
        }

        // Run in the card's existing worktree, or provision a fresh one, or fall
        // back to the workspace root.
        var runDirectory = workingDirectory ?? workspaceRoot
        if workingDirectory == nil,
           let root = workspaceRoot,
           let provisioner = worktreeProvisioner,
           let provisioned = await provisioner.provision(cardId: card.id, repoRoot: root) {
            runDirectory = provisioned.worktreePath
            continuation.yield(.provisioned(
                worktreePath: provisioned.worktreePath,
                branchName: provisioned.branchName
            ))
        }

        let started: AgentSessionStartedSession
        do {
            started = try await store.start(plan: plan, workingDirectory: runDirectory)
        } catch {
            runs[handle] = nil
            continuation.finish()
            throw error
        }
        run.sessionId = started.sessionId
        continuation.yield(.started(sessionId: started.sessionId))

        // Claude does not auto-start; drive the run by sending the card spec as
        // the prompt. (For codex/opencode this submits the first turn too.)
        let prompt = card.detail.isEmpty ? card.title : card.detail
        do {
            try await store.writeLine(sessionId: started.sessionId, text: prompt)
        } catch {
            continuation.yield(.output("Failed to send prompt to agent: \(error)\n"))
        }

        return KanbanDispatchSession(handle: handle, progress: stream)
    }

    func cancel(_ handle: KanbanDispatchHandle) async {
        guard let run = runs[handle] else { return }
        if let sessionId = run.sessionId {
            try? run.store.stop(sessionId: sessionId)
        }
        run.continuation.finish()
        runs[handle] = nil
    }

    /// Bridges one raw agent event onto the progress stream. Invoked on the main
    /// actor (every `AgentSessionProcessStore` emit is `@MainActor`).
    ///
    /// `provider.started` is ignored here: the native backend already synthesized
    /// `.started` inline from `store.start()` (see ``dispatch(card:workingDirectory:)``),
    /// so re-yielding it from the event would double-emit.
    private func handleAgentEvent(_ event: [String: Any], handle: KanbanDispatchHandle) {
        guard let run = runs[handle],
              let progress = AgentSessionEventMapping.sharedProgress(for: event) else { return }
        run.continuation.yield(progress)
        switch progress {
        case .turnComplete:
            // Print-mode heuristic: one card = one turn. Stop the process so it
            // exits and we get a terminal `provider.exit`. Tunable in smoke.
            if let sessionId = run.sessionId {
                try? run.store.stop(sessionId: sessionId)
            }
        case .exited:
            run.continuation.finish()
            runs[handle] = nil
        default:
            break
        }
    }
}

/// Maps the raw `AgentSessionProcessStore` events (`[String: Any]`) that every
/// Kanban dispatch backend observes onto the ``KanbanDispatchProgress``
/// vocabulary, so the store's wire keys and its `Int`/`Int32` exit-status
/// encoding live in exactly one place instead of being copy-pasted across
/// ``CmuxNativeBackend`` and ``CmuxLiveBackend``.
enum AgentSessionEventMapping {
    /// The progress event for the kinds common to every backend — output, turn
    /// completion, and process exit. Returns `nil` for events a backend handles
    /// itself, notably `provider.started` (native synthesizes it inline; the live
    /// backend translates it directly), so callers keep ownership of that case
    /// and of any per-backend side effects (auto-stop, observer teardown).
    static func sharedProgress(for event: [String: Any]) -> KanbanDispatchProgress? {
        switch event["type"] as? String {
        case "provider.output":
            guard let text = event["text"] as? String else { return nil }
            return .output(text)
        case "provider.turnComplete":
            return .turnComplete
        case "provider.exit":
            return .exited(status: exitStatus(for: event))
        default:
            return nil
        }
    }

    /// Decodes a `provider.exit` event's status. ``AgentSessionProcessStore`` emits
    /// it as `Int32` (`emitExit`); a plain `Int` is tolerated, and an absent or
    /// otherwise-typed value clamps to `0` (a clean exit).
    static func exitStatus(for event: [String: Any]) -> Int32 {
        let rawStatus = (event["status"] as? Int)
            ?? (event["status"] as? Int32).map(Int.init)
            ?? 0
        return Int32(clamping: rawStatus)
    }
}
