public import Foundation

/// Local reconnect credential for a paired Mac.
///
/// The token is stored in Keychain and referenced from SQLite by a non-secret
/// key, so trusted LAN/VPN reconnects do not need to send a Stack bearer token
/// over plaintext TCP.
public struct MobilePairedMacCredential: Codable, Equatable, Sendable {
    /// Bearer token minted by the Mac for attach-token RPC authorization.
    public var authToken: String
    /// Expiration time for the token, if the Mac supplied one.
    public var expiresAt: Date?

    /// Creates a paired-Mac reconnect credential.
    /// - Parameters:
    ///   - authToken: Bearer token minted by the Mac.
    ///   - expiresAt: Optional token expiration.
    public init(authToken: String, expiresAt: Date?) {
        self.authToken = authToken
        self.expiresAt = expiresAt
    }

    /// Whether the credential has a non-empty token and is not expired.
    /// - Parameter now: Clock value used for expiry comparison.
    public func isUsable(now: Date = Date()) -> Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (expiresAt.map { $0 > now } ?? true)
    }
}
