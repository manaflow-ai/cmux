public import Foundation

/// Invite details used to join a relay-backed collaboration session.
public struct CollaborationInvite: Codable, Equatable, Sendable {
    /// The relay WebSocket endpoint.
    public let relayURL: URL
    /// The short user-shareable session code.
    public let sessionCode: String
    /// The bearer token associated with the session code.
    public let token: String

    /// Creates collaboration invite details.
    /// - Parameters:
    ///   - relayURL: The relay WebSocket endpoint.
    ///   - sessionCode: The short user-shareable session code.
    ///   - token: The bearer token associated with the session code.
    public init(relayURL: URL, sessionCode: String, token: String) {
        self.relayURL = relayURL
        self.sessionCode = sessionCode
        self.token = token
    }
}
