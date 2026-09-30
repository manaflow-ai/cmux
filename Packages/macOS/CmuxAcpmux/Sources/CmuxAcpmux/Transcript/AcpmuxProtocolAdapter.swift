import Foundation

/// Heuristics that stand in for acpmux protocol fields that do not exist yet.
///
/// Each method names the field that will replace it. When the field lands, the reducer
/// reads it directly and the method is deleted; nothing else in the reducer guesses.
struct AcpmuxProtocolAdapter: Sendable {
    /// The prompt a `user_message` confirms.
    ///
    /// Replaced by: `user_message.promptId` echoed by every daemon build. Until then a
    /// record without it matches the oldest undelivered local echo with the same text.
    func promptID(forUserMessage msg: JSONValue, pendingEchoes: [(promptId: String, text: String)]) -> String? {
        if let promptId = msg["promptId"]?.stringValue { return promptId }
        let text = msg["text"]?.stringValue ?? ""
        return pendingEchoes.first { $0.text == text }?.promptId
    }

    /// Whether a new message, starting with `start`, redelivers the unfinished `abandoned`
    /// message directly before it (Codex resends the whole answer after a dropped stream).
    ///
    /// Replaced by: a `message_superseded {old, new}` record.
    func isRedelivery(of abandoned: String, restartingWith start: String) -> Bool {
        let head = start.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return false }
        return abandoned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(head)
    }

    /// Whether streamed prose is the harness's error text for a failed turn, which belongs
    /// in the failure row rather than in an assistant bubble.
    ///
    /// Replaced by: error text carried only on `turn_result`, marked so agents' error prose
    /// is not also streamed as `agent_message_chunk`.
    func isStreamedErrorProse(_ text: String, turnError: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && turnError.contains(trimmed)
    }
}
