public import Foundation

/// The request body sent to the daemon-ticket endpoint to mint a direct-connection ticket.
///
/// Identifies the target server (and optionally a specific session/attachment)
/// and the capabilities the client intends to exercise. Capabilities are sorted
/// so two equivalent requests hash and compare equal regardless of input order,
/// which lets the ticket service cache by request value.
public struct TerminalDaemonTicketRequest: Encodable, Hashable, Sendable {
    /// The target server identifier.
    public var serverID: String
    /// The team scoping the request, if any.
    public var teamID: String?
    /// A specific session to scope the ticket to, if any.
    public var sessionID: String?
    /// A specific attachment to scope the ticket to, if any.
    public var attachmentID: String?
    /// The capabilities the client intends to exercise, sorted for stable identity.
    public var capabilities: [String]

    /// Creates a ticket request, sorting `capabilities` for stable identity.
    /// - Parameters:
    ///   - serverID: The target server identifier.
    ///   - teamID: The team scoping the request, if any.
    ///   - sessionID: A specific session to scope to, if any.
    ///   - attachmentID: A specific attachment to scope to, if any.
    ///   - capabilities: The capabilities to request (defaults to `["session.attach"]`).
    public init(
        serverID: String,
        teamID: String? = nil,
        sessionID: String? = nil,
        attachmentID: String? = nil,
        capabilities: [String] = ["session.attach"]
    ) {
        self.serverID = serverID
        self.teamID = teamID
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.capabilities = capabilities.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case teamID = "team_id"
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case capabilities
    }
}
