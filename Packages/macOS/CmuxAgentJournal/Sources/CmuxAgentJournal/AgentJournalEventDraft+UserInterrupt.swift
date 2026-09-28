public import Foundation

extension AgentJournalEventDraft {
    /// Native event name for a turn the user interrupted from cmux.
    public static let userInterruptNativeEvent = "cmux.user_interrupt"

    /// A turn completion for a turn the user interrupted from cmux, such as a
    /// click on the terminal's Stop button.
    ///
    /// Claude Code runs no Stop hook when a turn is interrupted, so without
    /// this event the pane stays `running` until the next hook. The event
    /// carries no notification, so it never posts a "done" alert. If the agent
    /// keeps working, its next hook starts a turn and the pane runs again.
    ///
    /// - Parameters:
    ///   - source: The agent slug whose hooks journal this session (`claude`, `codex`).
    ///   - agentKey: The sidebar lifecycle key (`claude_code`, `codex`).
    ///   - sessionId: The interrupted session, as the agent's hooks report it.
    ///   - workspaceId: The owning workspace UUID string.
    ///   - surfaceId: The terminal surface UUID string.
    ///   - occurredAt: When the interrupt was sent.
    public static func userInterrupt(
        source: String,
        agentKey: String,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        occurredAt: Date = Date()
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            kind: .turnCompleted,
            occurredAtMs: Int64(occurredAt.timeIntervalSince1970 * 1_000),
            source: source,
            agentKey: agentKey,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            nativeEvent: userInterruptNativeEvent
        )
    }
}
