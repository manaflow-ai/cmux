public import CmuxHomeCore
public import Foundation

// The settings panel's reads and writes: the Chief's name and the transcript log.
extension ChiefConversationOwner {
    /// Renames every Chief the user owns (`agentClass == .chief`) in every
    /// conversation: the header pill, the list rows and the transcript read
    /// the participant's display name. Each changed conversation publishes
    /// `.conversationChanged` and persists; an unchanged one writes nothing.
    ///
    /// - Parameter name: The new name, trimmed; 1 to 60 characters.
    /// - Returns: The conversations that changed.
    /// - Throws: ``HomeRejection/invalid(_:)`` (`invalid_name`).
    @discardableResult
    public func renameChiefs(to name: String) throws -> [ConversationID] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw HomeRejection.invalid("invalid_name") }
        var changed: [ConversationID] = []
        for (id, state) in conversations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let stale = state.summary.participants.contains { $0.isChief && $0.ownerUser == me.id && $0.displayName != trimmed }
            guard stale else { continue }
            try updateConversation(id) { summary in
                for index in summary.participants.indices
                where summary.participants[index].isChief && summary.participants[index].ownerUser == me.id {
                    summary.participants[index].displayName = trimmed
                }
            }
            changed.append(id)
        }
        return changed
    }

    /// The JSON Lines file that keeps `conversation` (the settings panel's
    /// Show Transcript Log reveals it in Finder).
    ///
    /// - Parameter conversation: The conversation.
    /// - Returns: `<Chief home>/conversations/<id>.jsonl`; it may not exist yet.
    public nonisolated func logFile(for conversation: ConversationID) -> URL {
        Self.file(for: conversation, in: home)
    }
}
