import CMUXAgentLaunch
import Foundation

/// The registry's contribution to the sidebar session rows: the user's last
/// prompt, Claude's own title, and the "last typed" ordering.
extension AgentChatSessionRegistry {
    /// The prompt text carried by a `UserPromptSubmit` hook event.
    ///
    /// The CLI puts the (single-lined, 240-character) prompt into
    /// `tool_input.prompt` and only fills `context.lastUserMessage` when it was
    /// empty, so `tool_input` wins: `lastUserMessage` can carry the previous
    /// prompt. Returns nil when neither has text.
    nonisolated static func promptText(from event: WorkstreamEvent) -> String? {
        if let json = event.toolInputJSON,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["prompt", "text", "message"] {
                if let normalized = ClaudeTranscriptTailReader.normalized(object[key] as? String) {
                    return normalized
                }
            }
        }
        return ClaudeTranscriptTailReader.normalized(event.context?.lastUserMessage)
    }

    /// Applies a transcript tail read to a record.
    ///
    /// `aiTitle` adopts the newest transcript value. `lastPrompt` fills only
    /// when the record has no hook-sourced prompt yet (the hook text is fresher
    /// and timestamped). A read that changes nothing does not bump the version
    /// or notify, so repeated Stop events stay quiet.
    func applyTranscriptTail(sessionID: String, tail: ClaudeTranscriptTailReader.Tail) {
        guard let current = record(sessionID: sessionID) else { return }
        let nextTitle = tail.aiTitle ?? current.aiTitle
        let nextPrompt = current.lastPrompt ?? tail.lastPrompt
        guard nextTitle != current.aiTitle || nextPrompt != current.lastPrompt else { return }
        update(sessionID: sessionID) { record in
            record.aiTitle = nextTitle
            record.lastPrompt = nextPrompt
        }
    }

    /// Live (non-ended), surface-bound records that received a hook prompt,
    /// most recent prompt first. The first element is the session the user
    /// last typed into.
    func lastTypedLiveSessions() -> [AgentChatSessionRecord] {
        sessions(workspaceID: nil)
            .filter { $0.state != .ended && $0.surfaceID != nil && $0.lastPromptAt != nil }
            .sorted { lhs, rhs in
                guard let l = lhs.lastPromptAt, let r = rhs.lastPromptAt else { return false }
                if l != r { return l > r }
                return lhs.sessionID < rhs.sessionID
            }
    }
}
