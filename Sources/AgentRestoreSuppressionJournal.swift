import CmuxAgentJournal
import Foundation

/// Records duplicate-restore suppression without changing sidebar lifecycle.
struct AgentRestoreSuppressionJournal: Sendable {
    private let center: AgentJournalLifecycleCenter

    init(center: AgentJournalLifecycleCenter = .shared) {
        self.center = center
    }

    /// Queues a durable diagnostic event on the journal center's owned consumer.
    func record(
        kind: String,
        sessionID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        processID: Int
    ) {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = AgentJournalEventDraft.isValidSlug(normalizedKind)
            ? normalizedKind
            : "agent"
        let agentKey = source == "claude" ? "claude_code" : source
        let draft = AgentJournalEventDraft(
            kind: .stateChanged,
            occurredAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
            source: source,
            agentKey: agentKey,
            sessionId: sessionID,
            workspaceId: workspaceID.uuidString,
            surfaceId: surfaceID.uuidString,
            nativeEvent: "cmux_restore_suppressed_live_owner",
            detail: "duplicate restore suppressed; live owner pid=\(processID)"
        )
        guard draft.validationProblem() == nil else {
            return
        }
        center.enqueueAppend(draft)
    }
}
