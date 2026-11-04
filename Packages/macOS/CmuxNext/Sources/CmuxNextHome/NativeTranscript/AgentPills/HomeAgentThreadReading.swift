import CmuxHomeCore

/// What the agent pane reads and marks (``HomeAgentPane``): a seam over `HomeStore`, so tests pass a fake.
@MainActor
protocol HomeAgentThreadReading: AnyObject {
    /// Agent `peer`'s chat with the Chief in `conversation`, or nil when none is loaded.
    func agentThread(_ peer: String, in conversation: ConversationID) -> HomeAgentThread?
    /// The person saw agent `peer`'s newest report: its pill's unread dot clears.
    func markAgentSeen(_ peer: String, in conversation: ConversationID)
    /// The person wrote `text` to agent `peer` from the pane's composer: it reaches the agent through the
    /// Chief, and the Chief sees it (`HomeStore.sendAgentNote`).
    func sendToAgent(_ text: String, peer: String, in conversation: ConversationID)
}
