import CmuxHomeCore

/// The shared store is the agent pane's source (its run rows and the seen marks).
extension HomeStore: HomeAgentThreadReading {
    func sendToAgent(_ text: String, peer: String, in conversation: ConversationID) {
    }
}
