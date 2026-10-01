/// A message waiting for its turn.
public struct QueuedPrompt: Hashable, Sendable {
    /// The client identifier it was sent under, when it had one.
    public var clientMessageID: ClientMessageID?
    /// Position in the queue, from 1.
    public var position: Int
    /// The backend's own handle, for removing a message sent without a
    /// client identifier.
    public var ticket: UInt64?

    /// Creates a queue entry.
    /// - Parameters:
    ///   - clientMessageID: The client identifier, if any.
    ///   - position: Position from 1.
    ///   - ticket: The backend's handle, if any.
    public init(clientMessageID: ClientMessageID?, position: Int, ticket: UInt64? = nil) {
        self.clientMessageID = clientMessageID
        self.position = position
        self.ticket = ticket
    }
}
