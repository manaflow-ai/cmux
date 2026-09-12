import Foundation

/// Cache-first startup policy: which persisted credentials are still worth
/// binding with, and how a fresh mint becomes cache entries.
public struct NextTransportRelayCredentialCachePolicy: Sendable {
    /// A cached token must outlive "now" by this margin to be included in
    /// the endpoint's initial relay map; anything tighter would expire
    /// during the bind/handshake and produce a silently dead relay route.
    let reuseMarginSeconds: Int64

    /// Creates a cache policy with a minimum remaining validity window.
    ///
    /// - Parameter reuseMarginSeconds: Seconds reserved for endpoint startup.
    public init(reuseMarginSeconds: Int64 = 30) {
        self.reuseMarginSeconds = reuseMarginSeconds
    }

    /// Selects credentials that outlive the startup margin or have unknown expiry.
    ///
    /// - Parameters:
    ///   - cached: Persisted credentials to consider.
    ///   - now: Current epoch seconds.
    ///   - marginSeconds: An optional per-call override of the startup margin.
    /// - Returns: Usable credentials in their original order.
    public func usable(
        _ cached: [NextTransportCachedRelayCredential],
        now: Int64,
        marginSeconds: Int64? = nil
    ) -> [NextTransportCachedRelayCredential] {
        let marginSeconds = marginSeconds ?? reuseMarginSeconds
        return cached.filter { credential in
            guard let expiresAt = credential.expiresAt else { return true }
            return expiresAt > now + marginSeconds
        }
    }

    /// Cache entries from a fresh mint. `Credential.expiresAt` is populated
    /// whenever an expiry is knowable (server value or the token's own JWT
    /// `exp`); a credential with no visible expiry cannot be validity-checked
    /// at the next launch, so it remains cached and follows the bounded
    /// fallback cadence rather than disabling renewal permanently.
    ///
    /// - Parameter credentials: Freshly minted broker credentials.
    /// - Returns: Their protected-persistence representations.
    public func entries(
        from credentials: [BrokerCredentialClient.Credential]
    ) -> [NextTransportCachedRelayCredential] {
        credentials.map { credential in
            NextTransportCachedRelayCredential(
                relayUrl: credential.relayUrl, token: credential.token,
                expiresAt: credential.expiresAt)
        }
    }

    /// Encodes cache entries without persisting credential material.
    ///
    /// - Parameter entries: The credentials to encode.
    /// - Returns: JSON data, or nil if encoding fails.
    public func encode(_ entries: [NextTransportCachedRelayCredential]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// Decodes an optional startup cache, treating corrupt cache data as absent.
    ///
    /// - Parameter data: Previously encoded cache data.
    /// - Returns: Decoded credentials, or an empty cache when decoding fails.
    public func decode(_ data: Data) -> [NextTransportCachedRelayCredential] {
        (try? JSONDecoder().decode([NextTransportCachedRelayCredential].self, from: data)) ?? []
    }
}
