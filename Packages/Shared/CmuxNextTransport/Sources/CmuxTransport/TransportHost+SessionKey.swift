import Foundation

extension TransportHost {
    /// Supersession is keyed by (device ID, app identity), not by network key,
    /// so a reinstalled app with a freshly generated key still instantly
    /// replaces its own old session (contract 1.5, 4.5).
    public struct SessionKey: Hashable, Sendable {
        /// Durable device identifier authenticated by the admitted grant.
        public let deviceID: String
        /// App identity authenticated by the admitted grant.
        public let appIdentity: String
    }
}
