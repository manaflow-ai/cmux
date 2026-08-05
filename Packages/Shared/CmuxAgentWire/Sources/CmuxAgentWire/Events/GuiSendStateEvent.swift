public import CmuxAgentReplica

/// Event payload carrying the whole current send-ticket value.
public struct GuiSendStateEvent: Codable, Hashable, Sendable {
    /// The whole current send-ticket value.
    public let ticket: SendTicket

    /// Creates a send-state payload.
    /// - Parameter ticket: The whole current send-ticket value.
    public init(ticket: SendTicket) {
        self.ticket = ticket
    }
}
