public import CmuxAgentReplica

/// Parameters for submitting an idempotent send ticket.
public struct GuiSendParams: Codable, Hashable, Sendable {
    /// The destination session.
    public let sessionID: AgentSessionID
    /// The client-minted UUID string used for idempotency.
    public let ticketID: String
    /// Optional user text.
    public let text: String?
    /// Optional attachment descriptors; binary transfer is outside this contract.
    public let attachments: [GuiSendAttachment]?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case ticketID = "ticket_id"
        case text
        case attachments
    }

    /// Creates send parameters.
    /// - Parameters:
    ///   - sessionID: The destination session.
    ///   - ticketID: The client-minted UUID string.
    ///   - text: Optional user text.
    ///   - attachments: Optional attachment descriptors.
    public init(
        sessionID: AgentSessionID,
        ticketID: String,
        text: String? = nil,
        attachments: [GuiSendAttachment]? = nil
    ) {
        self.sessionID = sessionID
        self.ticketID = ticketID
        self.text = text
        self.attachments = attachments
    }
}

/// Result acknowledging Mac-side acceptance of a send ticket.
public struct GuiSendResult: Codable, Hashable, Sendable {
    /// Whether the Mac accepted the ticket.
    public let accepted: Bool
    /// Whether the accepted ticket is queued on the Mac.
    public let queuedOnMac: Bool

    private enum CodingKeys: String, CodingKey {
        case accepted
        case queuedOnMac = "queued_on_mac"
    }

    /// Creates a send result.
    /// - Parameters:
    ///   - accepted: Whether the Mac accepted the ticket.
    ///   - queuedOnMac: Whether the accepted ticket is queued on the Mac.
    public init(accepted: Bool, queuedOnMac: Bool) {
        self.accepted = accepted
        self.queuedOnMac = queuedOnMac
    }
}
