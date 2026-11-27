import Foundation

extension RemoteHostAppRequest {
    /// The app socket's credentials for this app's own process. The secret must never be logged or stored.
    public struct Response: Decodable, Sendable, Equatable {
        public var socket: String
        public var secret: String
        public var hostPID: Int32

        enum CodingKeys: String, CodingKey {
            case socket, secret
            case hostPID = "host_pid"
        }
    }
}
