/// Something that happened in a conversation, in the GUI's own terms.
///
/// A backend adapter translates whatever its backend sends into these; the
/// reducer folds them into ``ConversationState``. Nothing here is specific
/// to one backend: backend-only items travel as ``extension(_:)``.
public enum ConversationEvent: Hashable, Sendable {
    /// The agent received a user message (it started a turn, or steered one).
    case userMessage(clientMessageID: ClientMessageID?, text: String, attachments: [ConversationAttachment], steer: Bool)
    /// A user message is waiting its turn. `held` means it waits for files.
    case userMessageQueued(clientMessageID: ClientMessageID?, text: String, attachments: [ConversationAttachment], position: Int, held: Bool)
    /// The queue's order changed.
    case queueChanged([QueuedPrompt])
    /// A waiting user message was removed before it ran.
    case userMessageDequeued(clientMessageID: ClientMessageID?, text: String)
    /// A user message left the queue because its files never arrived.
    case userMessageFailed(clientMessageID: ClientMessageID?, text: String, attachments: [ConversationAttachment], failedUploadIDs: [String])
    /// An attached file's state changed.
    case attachmentChanged(ConversationAttachment)
    /// More bytes of an attached file arrived at the backend.
    case attachmentProgress(uploadID: String, received: UInt64)
    /// The agent streamed text.
    case assistantText(String)
    /// The agent streamed visible reasoning.
    case reasoningText(String)
    /// The agent started a tool call or other work.
    case activityStarted(id: String, ActivityItem)
    /// A running activity changed; `nil` fields stay as they were.
    case activityUpdated(id: String, status: String?, title: String?, detail: String?)
    /// The agent's plan, replacing the previous one in this turn.
    case plan([PlanEntry])
    /// The agent asks for approval or an answer.
    case approvalRequested(ApprovalRequest)
    /// An approval request was answered (by anyone, or automatically).
    case approvalResolved(id: String, optionID: String?)
    /// A turn started.
    case turnStarted(clientMessageID: ClientMessageID?)
    /// A turn ended. `error` is set when it failed.
    case turnEnded(stopReason: String?, error: String?)
    /// The agent's status changed.
    case statusChanged(ConversationStatus)
    /// The conversation got a title.
    case titleChanged(String)
    /// The agent's mode changed.
    case modeChanged(String)
    /// The agent's model changed.
    case modelChanged(String)
    /// Context-window use, when the backend reports it.
    case usage(used: UInt64, size: UInt64?)
    /// A short status line worth showing (a failover, a restore).
    case notice(String)
    /// An error worth showing.
    case error(String)
    /// The conversation was deleted.
    case deleted
    /// A backend-specific item.
    case `extension`(ExtensionItem)
}
