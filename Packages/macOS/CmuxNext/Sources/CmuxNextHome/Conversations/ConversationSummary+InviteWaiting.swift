import CmuxHomeCore

extension ConversationSummary {
    /// The sender's state of a DM whose other person has not joined yet (DESIGN 2.5): "Waiting
    /// for a***@manaflow.ai to accept", or a nameless line when the invite carries no
    /// readable address; nil once nobody is waiting. Never an internal id.
    func homeInviteWaiting(me: ParticipantID?) -> String? {
        guard let invited = participants.first(where: { $0.id != me && $0.membership == .invited }) else { return nil }
        let name = invited.visibleName
        return name.isEmpty ? HomeConversationStrings.invitedLabel : HomeConversationStrings.waitingFor(name)
    }
}
