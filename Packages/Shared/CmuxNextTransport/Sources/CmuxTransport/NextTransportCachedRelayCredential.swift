import Foundation

/// One persisted last-good relay credential: enough to re-attach the relay
/// on next launch without a broker round trip. Stored (JSON array) in a
/// macOS Keychain generic-password item; never in UserDefaults.
public struct NextTransportCachedRelayCredential: Codable, Sendable, Equatable {
    /// The relay's HTTPS origin.
    public var relayUrl: String
    /// The endpoint-bound credential, stored only in protected persistence.
    public var token: String
    /// Epoch seconds at which the relay stops honoring the token, when the
    /// broker exposed a claim. `nil` credentials remain in the cache and use
    /// the bounded fallback renewal cadence.
    public var expiresAt: Int64?

    /// Creates a cache entry from a broker-issued credential.
    ///
    /// - Parameters:
    ///   - relayUrl: The relay's HTTPS origin.
    ///   - token: The endpoint-bound credential.
    ///   - expiresAt: Expiry in epoch seconds, or nil when unknown.
    public init(relayUrl: String, token: String, expiresAt: Int64?) {
        self.relayUrl = relayUrl
        self.token = token
        self.expiresAt = expiresAt
    }
}
