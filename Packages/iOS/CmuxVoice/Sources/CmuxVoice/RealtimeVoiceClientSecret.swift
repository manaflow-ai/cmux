public import Foundation

/// A short-lived OpenAI Realtime credential minted by the authenticated cmux backend.
public struct RealtimeVoiceClientSecret: Decodable, Equatable, Sendable {
    /// Ephemeral credential used only to establish one Realtime connection.
    public let value: String
    /// Unix timestamp after which the credential cannot establish a connection.
    public let expiresAt: Int
    /// Realtime model selected and enforced by the backend.
    public let model: String

    private enum CodingKeys: String, CodingKey {
        case value
        case expiresAt = "expires_at"
        case model
    }
}
