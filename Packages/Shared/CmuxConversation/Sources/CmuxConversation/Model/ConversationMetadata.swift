/// Facts about a conversation that a backend reports outside its event
/// history: the latest title, status, mode and model.
public struct ConversationMetadata: Hashable, Sendable {
    /// The title, when known.
    public var title: String?
    /// What the agent is doing.
    public var status: ConversationStatus?
    /// The agent's mode, when known.
    public var mode: String?
    /// The agent's model, when known.
    public var model: String?

    /// Creates metadata; `nil` fields leave the state unchanged.
    /// - Parameters:
    ///   - title: The title.
    ///   - status: The agent's status.
    ///   - mode: The agent's mode.
    ///   - model: The agent's model.
    public init(title: String? = nil, status: ConversationStatus? = nil, mode: String? = nil, model: String? = nil) {
        self.title = title
        self.status = status
        self.mode = mode
        self.model = model
    }
}
