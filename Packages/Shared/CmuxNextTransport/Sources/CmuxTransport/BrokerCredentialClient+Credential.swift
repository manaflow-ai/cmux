import Foundation

extension BrokerCredentialClient {
    /// A broker-issued bearer credential scoped to one relay endpoint.
    public struct Credential: Sendable {
        /// Relay URL to which the token may be applied.
        public let relayUrl: String
        /// Secret relay admission token; never render it in diagnostics.
        public let token: String
        /// Earliest known broker or JWT expiry in Unix seconds, or nil when neither is visible.
        public let expiresAt: Int64?
    }
}
