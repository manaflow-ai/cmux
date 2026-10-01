/// Something the user asks a conversation to do.
public enum ConversationCommand: Hashable, Sendable {
    /// Send a message (files are uploaded separately, see ``AttachmentUploading``).
    case send(OutgoingMessage)
    /// Stop the running turn.
    case cancelTurn
    /// Remove a waiting message from the queue.
    case dequeue(ClientMessageID)
    /// Send again a message that failed for want of files.
    case retry(ClientMessageID)
    /// Answer an approval request.
    case answerApproval(id: String, optionID: String)
    /// Change the agent's mode.
    case setMode(String)
    /// Change the agent's model.
    case setModel(String)
    /// Stop the conversation's agent; history is kept.
    case stop
    /// Delete the conversation and its history.
    case delete
}
