public import Foundation

/// Records one locally-originated send attempt.
public struct SendTicket: Codable, Hashable, Sendable, Identifiable {
    /// The stable ticket UUID.
    public let id: UUID
    /// The session this ticket belongs to.
    public let sessionID: AgentSessionID
    /// The text submitted by the user.
    public let text: String
    /// The number of attachments submitted with the ticket.
    public let attachmentCount: Int
    /// The replicated ticket state.
    public let state: SendTicketState
    /// The injected clock tick when the ticket was created.
    public let createdAt: Int

    /// Creates a send ticket.
    /// - Parameters:
    ///   - id: The stable UUID.
    ///   - sessionID: The owning session identifier.
    ///   - text: The submitted text.
    ///   - attachmentCount: The submitted attachment count.
    ///   - state: The current ticket state.
    ///   - createdAt: The injected clock tick.
    public init(
        id: UUID,
        sessionID: AgentSessionID,
        text: String,
        attachmentCount: Int,
        state: SendTicketState,
        createdAt: Int
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.attachmentCount = attachmentCount
        self.state = state
        self.createdAt = createdAt
    }
}
