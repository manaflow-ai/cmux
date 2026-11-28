extension CmxConnectivityDiscoveryScope {
    /// The caller's own binding, which remains visible even when it does not
    /// satisfy the peer selector.
    public struct LocalBinding: Codable, Equatable, Sendable {
        /// The durable device identifier that owns the local endpoint.
        public let deviceID: String

        /// The app installation identifier that owns the local endpoint.
        public let appInstanceID: String

        /// The exact build tag registered by the local app.
        public let tag: String

        /// The platform hosting the local endpoint.
        public let platform: CmxIrohPlatform

        private enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case appInstanceID = "app_instance_id"
            case tag
            case platform
        }
    }
}
