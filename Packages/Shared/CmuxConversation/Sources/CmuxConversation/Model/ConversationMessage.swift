/// Text exchanged in a conversation, from the user or the agent.
public struct ConversationMessage: Hashable, Sendable {
    /// Who wrote it.
    public enum Role: Hashable, Sendable {
        /// The person using the GUI (or another client of the same account).
        case user
        /// The agent.
        case assistant
    }

    /// Who wrote it.
    public var role: Role
    /// The text, accumulated as it streams in.
    public var text: String
    /// Upload identifiers of attached files, in order. Look them up in
    /// ``ConversationState/attachments``.
    public var attachmentIDs: [String]
    /// For user messages: the client identifier it was sent under.
    public var clientMessageID: ClientMessageID?
    /// For user messages: where it is on its way.
    public var delivery: DeliveryState?

    /// Creates a message.
    /// - Parameters:
    ///   - role: Who wrote it.
    ///   - text: The text so far.
    ///   - attachmentIDs: Upload identifiers of attached files.
    ///   - clientMessageID: Client identifier, for user messages.
    ///   - delivery: Delivery state, for user messages.
    public init(role: Role, text: String, attachmentIDs: [String] = [], clientMessageID: ClientMessageID? = nil, delivery: DeliveryState? = nil) {
        self.role = role
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.clientMessageID = clientMessageID
        self.delivery = delivery
    }
}
