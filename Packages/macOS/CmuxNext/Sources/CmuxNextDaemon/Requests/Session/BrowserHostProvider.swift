import Foundation

/// `browser-host-provider` (`browser-host-provider-v1`): the provider credentials of the
/// daemon's browser host. The daemon answers only the verified app connection (role `main`
/// plus a proof); the secret must never be logged or stored.
public struct BrowserHostProviderRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The provider socket (`browser-host-provider.sock`).
        public var socket: String
        /// The host launch's provider secret.
        public var secret: String
        /// The host process.
        public var hostPID: Int32
        /// The process that holds the listening socket (the daemon under socket activation);
        /// absent from older daemons. Send the secret only to a peer that is one of the two.
        public var listenerPID: Int32?

        enum CodingKeys: String, CodingKey {
            case socket, secret
            case hostPID = "host_pid"
            case listenerPID = "listener_pid"
        }
    }
    public static let command = "browser-host-provider"
    public init() {}
}
