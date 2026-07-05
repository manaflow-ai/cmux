import Foundation

/// Parsed Discord Gateway event category relevant to the inbox.
public enum DiscordGatewayEvent: Equatable, Sendable {
    /// A message create dispatch produced an inbox item.
    case message(InboxItem)
    /// Discord instructed the client to reconnect and resume.
    case reconnect
    /// The Gateway session is invalid and must identify or resume accordingly.
    case invalidSession
    /// The payload was not relevant to the inbox.
    case ignored
}
