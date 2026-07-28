/// Errors produced while normalizing an already-read conversation.
public enum ConversationTransferError: Error, Equatable, Sendable {
    /// No eligible user or assistant content remained after applying the policy.
    case emptyConversation
}
