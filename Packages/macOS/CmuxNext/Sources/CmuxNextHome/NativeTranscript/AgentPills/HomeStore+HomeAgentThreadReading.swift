import CmuxHomeCore

/// The shared store is the agent pane's source (its run rows and the seen marks) and its composer's way out.
extension HomeStore: HomeAgentThreadReading {
    func sendToAgent(_ text: String, peer: String, in conversation: ConversationID) {
        // task-owner: one send; the store's intent log owns its resend and Not Delivered state
        Task { try? await sendAgentNote(text, to: peer, in: conversation) }
    }
}
