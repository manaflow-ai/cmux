/// A message the user sends, before and while it travels to the backend.
public struct OutgoingMessage: Hashable, Sendable, Codable {
    /// The client identifier; the same on every resend.
    public var clientMessageID: ClientMessageID
    /// The text.
    public var text: String
    /// Files it carries.
    public var attachments: [OutgoingAttachment]
    /// Send it into the running turn instead of queueing it, when supported.
    public var steer: Bool

    /// Creates a message.
    /// - Parameters:
    ///   - clientMessageID: Client identifier; defaults to a fresh one.
    ///   - text: The text.
    ///   - attachments: Files it carries.
    ///   - steer: Steer the running turn.
    public init(clientMessageID: ClientMessageID = .generate(), text: String, attachments: [OutgoingAttachment] = [], steer: Bool = false) {
        self.clientMessageID = clientMessageID
        self.text = text
        self.attachments = attachments
        self.steer = steer
    }
}
