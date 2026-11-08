extension CmxConnectivityDiscoveryScope {
    /// Opposite-platform bindings that this runtime may connect to or admit.
    public struct PeerBindings: Codable, Equatable, Sendable {
        /// The platform required for every selected peer binding.
        public let platform: CmxIrohPlatform

        /// Canonical build tags accepted by the peer selector, or all tags when absent.
        public let tags: [String]?

        /// The required pairing state, or either state when absent.
        public let pairingEnabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case platform
            case tags
            case pairingEnabled = "pairing_enabled"
        }
    }
}
