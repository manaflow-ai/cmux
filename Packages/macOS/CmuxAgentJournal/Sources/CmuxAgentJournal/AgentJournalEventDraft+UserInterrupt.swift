import Foundation

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
    ///   - occurredAtMs: The interrupted session's accepted causal timestamp.
    public static func userInterrupt(
        source: String,
        agentKey: String,
        sessionId: String?,
        workspaceId: String,
        surfaceId: String,
        occurredAtMs: Int64
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            kind: .turnCompleted,
            occurredAtMs: occurredAtMs,
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
    /// Last accepted lifecycle sequence for every running session that an
    /// interrupt request is allowed to settle.
    public func userInterruptSessionBoundary(
        surfaceId: String,
        agentKey: String
    ) -> [String: Int64] {
        let bySession = sessions[surfaceId]?[agentKey] ?? [:]
        return bySession.reduce(into: [:]) { boundary, entry in
            let (sessionKey, session) = entry
            guard !session.ended, session.phase == .running else { return }
            boundary[sessionKey] = session.lastSequence
        }
    }

    /// Interrupt events for every live, running session of `agentKey` on
    /// `surfaceId` that has not advanced beyond the captured interrupt
    /// boundary, including sessions whose hooks came over a relay.
    ///
    /// - Parameters:
    ///   - surfaceId: The surface UUID string, as the reducer keys it.
    ///   - workspaceId: The owning workspace UUID string.
    ///   - agentKey: The sidebar lifecycle key (`claude_code`).
    ///   - source: The agent slug whose hooks journal these sessions (`claude`).
    ///   - sessionBoundary: Session key to last accepted lifecycle sequence
    ///     captured when the interrupt request reached the journal consumer.
    /// - Returns: One draft per running session; empty when none is running.
    public func userInterruptDrafts(
        surfaceId: String,
        workspaceId: String,
        agentKey: String,
        source: String,
        sessionBoundary: [String: Int64]
    ) -> [AgentJournalEventDraft] {
        let bySession = sessions[surfaceId]?[agentKey] ?? [:]
        return bySession.keys.sorted().compactMap { sessionKey in
            guard let session = bySession[sessionKey],
                  sessionBoundary[sessionKey] == session.lastSequence,
                  !session.ended,
                  session.phase == .running else {
                return nil
            }
            let sessionId = sessionKey == "@\(source)" ? nil : sessionKey
            return .userInterrupt(
                source: source,
                agentKey: agentKey,
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                occurredAtMs: session.lastOccurredAtMs
            )
        }
    }
}
