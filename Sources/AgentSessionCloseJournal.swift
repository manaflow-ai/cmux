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
