public import Foundation
internal import CmuxTerminalCore

/// A short-lived, capability-scoped ticket authorizing a direct daemon connection.
///
/// Minted by the daemon-ticket endpoint in response to a
/// ``TerminalDaemonTicketRequest``. Carries the opaque ticket string, the direct
/// connection URL, the TLS pins to validate the direct endpoint against, and the
/// session/attachment the ticket is bound to. Direct-TLS pins are normalized on
/// construction so equal pin sets always compare equal.
public struct TerminalDaemonTicket: Decodable, Equatable, Sendable {
    /// The opaque ticket string presented to the daemon.
    public var ticket: String
    /// The direct connection URL the ticket authorizes.
    public var directURL: URL
    /// The TLS certificate pins to validate the direct endpoint against, normalized.
    public var directTLSPins: [String]
    /// The session the ticket is bound to.
    public var sessionID: String
    /// The attachment the ticket is bound to.
    public var attachmentID: String
    /// The time after which the ticket is no longer valid.
    public var expiresAt: Date

    /// Creates a ticket value, normalizing the direct-TLS pins.
    /// - Parameters:
    ///   - ticket: The opaque ticket string.
    ///   - directURL: The direct connection URL.
    ///   - directTLSPins: The TLS pins (normalized on assignment).
    ///   - sessionID: The bound session identifier.
    ///   - attachmentID: The bound attachment identifier.
    ///   - expiresAt: The ticket expiry time.
    public init(
        ticket: String,
        directURL: URL,
        directTLSPins: [String] = [],
        sessionID: String,
        attachmentID: String,
        expiresAt: Date
    ) {
        self.ticket = ticket
        self.directURL = directURL
        self.directTLSPins = directTLSPins.normalizedTerminalPins
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case ticket
        case directURL = "direct_url"
        case directTLSPins = "direct_tls_pins"
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case expiresAt = "expires_at"
    }

    /// Decodes a ticket, normalizing the direct-TLS pins.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A `DecodingError` if a required field is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try container.decode(String.self, forKey: .ticket)
        directURL = try container.decode(URL.self, forKey: .directURL)
        directTLSPins = try container.decodeIfPresent([String].self, forKey: .directTLSPins)?
            .normalizedTerminalPins ?? []
        sessionID = try container.decode(String.self, forKey: .sessionID)
        attachmentID = try container.decode(String.self, forKey: .attachmentID)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}
