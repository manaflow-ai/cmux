import CmuxAgentJournal
import Foundation

/// Journals the end of agent sessions whose terminal the user closed.
///
/// Closing a pane kills its agent, usually before the agent's own session-end
/// hook can report it, so the journal would keep the session open. Crash
/// recovery treats an open session as lost with the app and would reopen a
/// pane the user closed on purpose. The app owns the close, so it records the
/// end itself.
struct AgentSessionCloseJournal: Sendable {
    private let center: AgentJournalLifecycleCenter

    init(center: AgentJournalLifecycleCenter = .shared) {
        self.center = center
    }

    /// Queues one `agent.session.ended` event per session on the journal
    /// center's owned consumer, without blocking on SQLite I/O.
    func recordClosed(
        sessions: [(kind: String, sessionID: String)],
        workspaceID: UUID,
        surfaceID: UUID,
        now: Date = Date()
    ) {
        let occurredAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        var seen = Set<String>()
        for session in sessions {
            let kind = session.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let sessionID = session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionID.isEmpty,
                  AgentJournalEventDraft.isValidSlug(kind),
                  seen.insert("\(kind)\u{0}\(sessionID)").inserted else { continue }
            let draft = AgentJournalEventDraft(
                kind: .sessionEnded,
                occurredAtMs: occurredAtMs,
                source: kind,
                agentKey: kind == "claude" ? "claude_code" : kind,
                sessionId: sessionID,
                workspaceId: workspaceID.uuidString,
                surfaceId: surfaceID.uuidString,
                nativeEvent: "cmux_surface_closed",
                detail: "terminal closed by the user"
            )
            guard draft.validationProblem() == nil else { continue }
            center.enqueueAppend(draft)
        }
    }
}

/// Owns terminal panels that can carry agent sessions: a workspace or a Dock.
///
/// Both close panels through their own teardown, and both call
/// ``journalClosedAgentSessions(panelId:)`` from it, so a Claude pane closed
/// anywhere is journaled the same way.
@MainActor
protocol AgentSessionPanelHost: AnyObject {
    /// The workspace the journal attributes a closed panel's sessions to.
    var agentSessionWorkspaceID: UUID { get }
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] { get }
    /// Hook bindings that can name the agent session a panel carries.
    func agentSessionBindingsForClose(panelId: UUID) -> [SurfaceResumeBindingSnapshot]
    var restoredAgentLifecycle: RestoredAgentLifecycleCoordinator { get }
    var deferredAgentResumeRestoresByPanelId: [UUID: DeferredAgentResumeRestore] { get }
    var agentSessionCloseJournal: AgentSessionCloseJournal { get }
}

extension AgentSessionPanelHost {
    func agentSessionBindingsForClose(panelId: UUID) -> [SurfaceResumeBindingSnapshot] {
        surfaceResumeBindingsByPanelId[panelId].map { [$0] } ?? []
    }

    /// Records the end of the recoverable agent sessions this panel carries,
    /// so crash recovery never reopens a terminal the user closed. Call it
    /// before the panel's bindings and restore state are discarded. Skipped
    /// while the app quits: those sessions end with the app, and startup
    /// restore owns them.
    func journalClosedAgentSessions(panelId: UUID) {
        guard AppDelegate.shared?.isTerminatingApp != true else { return }
        let recoverable = Set(AgentSessionRecovery.recoverableKinds.map(\.rawValue))
        var sessions: [(kind: String, sessionID: String)] = []
        for binding in agentSessionBindingsForClose(panelId: panelId) where binding.isAgentHookBinding {
            guard let kind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  recoverable.contains(kind),
                  let sessionID = binding.checkpointId else { continue }
            sessions.append((kind, sessionID))
        }
        let restoredAgents = [
            restoredAgentLifecycle.snapshotsByPanelId[panelId],
            deferredAgentResumeRestoresByPanelId[panelId]?.restorableAgent,
        ]
        for agent in restoredAgents.compactMap({ $0 }) where recoverable.contains(agent.kind.rawValue) {
            sessions.append((agent.kind.rawValue, agent.sessionId))
        }
        guard !sessions.isEmpty else { return }
        // A session another panel still carries (a restore that lost to a live
        // owner, or a stale snapshot resumed elsewhere) did not end here.
        let carriedElsewhere = AppDelegate.shared?.openAgentSessionIdsForRecovery(excludingPanelId: panelId) ?? []
        sessions.removeAll { carriedElsewhere.contains($0.sessionID) }
        guard !sessions.isEmpty else { return }
        agentSessionCloseJournal.recordClosed(
            sessions: sessions,
            workspaceID: agentSessionWorkspaceID,
            surfaceID: panelId
        )
    }
}

extension Workspace: AgentSessionPanelHost {
    var agentSessionWorkspaceID: UUID { id }
}

extension DockSplitStore: AgentSessionPanelHost {
    var agentSessionWorkspaceID: UUID { workspaceId }

    /// The effective binding, plus the agent-hook binding the Dock keeps
    /// aside while process detection shows another one (a tmux binding).
    func agentSessionBindingsForClose(panelId: UUID) -> [SurfaceResumeBindingSnapshot] {
        [surfaceResumeBindingsByPanelId[panelId], managedAgentResumeBindingsByPanelId[panelId]].compactMap { $0 }
    }
}
