import CmuxAgentChat
import CmuxMobileHost
import Foundation

/// The prompt list of the agent session running in one terminal surface.
struct AgentTurnOutlineSnapshot: Equatable, Sendable {
    let sessionID: String
    let agentKind: ChatAgentKind
    /// One entry per prompt, oldest first.
    let entries: [ChatOutlineEntry]
    /// Whether older prompts exist that the outline does not hold.
    let isHeadTruncated: Bool
}

extension AgentChatTranscriptService {
    /// Wakeups for when the outline of `surfaceID` may have changed: a new
    /// transcript batch, or the surface's session starting, ending or moving.
    func turnOutlineChanges(surfaceID: UUID) -> AsyncStream<Void> {
        turnOutlineChanges.stream(surfaceID: surfaceID.uuidString)
    }

    /// The prompt outline of the live Claude Code or Codex session bound to a
    /// terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface.
    /// - Returns: `nil` when no recognized agent session is live in the
    ///   surface; an empty outline while its transcript is not readable yet.
    func turnOutline(surfaceID: UUID) async -> AgentTurnOutlineSnapshot? {
        guard let record = registry.liveSession(surfaceID: surfaceID.uuidString) else { return nil }
        switch record.agentKind {
        case .claude, .codex:
            break
        case .other:
            return nil
        }
        guard let tailer = await turnOutlineTailer(for: record) else {
            return AgentTurnOutlineSnapshot(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                entries: [],
                isHeadTruncated: false
            )
        }
        await tailer.start()
        // The session may have ended or moved while the transcript loaded.
        guard registry.liveSession(surfaceID: surfaceID.uuidString)?.sessionID == record.sessionID else {
            return nil
        }
        return AgentTurnOutlineSnapshot(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            entries: await tailer.outlineEntries,
            isHeadTruncated: await tailer.isOutlineHeadTruncated
        )
    }
}
