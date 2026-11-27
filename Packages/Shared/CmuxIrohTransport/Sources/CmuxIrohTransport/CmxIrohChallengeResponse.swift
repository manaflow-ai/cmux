/// Broker-issued nonce used for one endpoint registration attempt.
public struct CmxIrohChallengeResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
        case expiresAt = "expires_at"
    }

    /// One-use broker challenge UUID.
    public let challengeID: String
    /// Canonical base64url encoding of 32 random bytes.
    public let nonce: String
    /// Broker expiry supplied for scheduling and diagnostics.
    public let expiresAt: String

    /// Creates a challenge response value.
    public init(challengeID: String, nonce: String, expiresAt: String) {
        self.challengeID = challengeID
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}
