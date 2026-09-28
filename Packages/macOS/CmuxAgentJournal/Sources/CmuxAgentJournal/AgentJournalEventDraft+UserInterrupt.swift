public import Foundation

extension AgentJournalEventDraft {
    /// Native event name for a turn the user interrupted from cmux.
    public static let userInterruptNativeEvent = "cmux.user_interrupt"

    /// A turn completion for a turn the user interrupted from cmux, such as a
    /// click on the terminal's Stop button.
    ///
    /// Claude Code runs no Stop hook when a turn is interrupted, so without
    /// this event the pane stays `running` until the next hook. The event
    /// carries no notification, so it never posts a "done" alert. If Claude
    /// keeps working, its next PreToolUse hook declares the pane running again.
    ///
    /// - Parameters:
    ///   - source: The agent slug whose hooks journal this session (`claude`, `codex`).
    ///   - agentKey: The sidebar lifecycle key (`claude_code`, `codex`).
    ///   - sessionId: The interrupted session, as the agent's hooks report it,
    ///     or `nil` for a source whose hooks report none.
    ///   - workspaceId: The owning workspace UUID string.
    ///   - surfaceId: The terminal surface UUID string.
    ///   - occurredAt: When the interrupt was sent.
    public static func userInterrupt(
        source: String,
        agentKey: String,
        sessionId: String?,
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

extension AgentLifecycleReducerState {
    /// Interrupt events for every live, running session of `agentKey` on
    /// `surfaceId`, so an interrupt settles exactly the sessions the journal
    /// has running there, including ones whose hooks came over a relay.
    ///
    /// - Parameters:
    ///   - surfaceId: The surface UUID string, as the reducer keys it.
    ///   - workspaceId: The owning workspace UUID string.
    ///   - agentKey: The sidebar lifecycle key (`claude_code`).
    ///   - source: The agent slug whose hooks journal these sessions (`claude`).
    ///   - occurredAt: When the interrupt was sent.
    /// - Returns: One draft per running session; empty when none is running.
    public func userInterruptDrafts(
        surfaceId: String,
        workspaceId: String,
        agentKey: String,
        source: String,
        occurredAt: Date = Date()
    ) -> [AgentJournalEventDraft] {
        let bySession = sessions[surfaceId]?[agentKey] ?? [:]
        return bySession.keys.sorted().compactMap { sessionKey in
            guard let session = bySession[sessionKey], !session.ended, session.phase == .running else {
                return nil
            }
            let sessionId = sessionKey == "@\(source)" ? nil : sessionKey
            return .userInterrupt(
                source: source,
                agentKey: agentKey,
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                occurredAt: occurredAt
            )
        }
    }
}
