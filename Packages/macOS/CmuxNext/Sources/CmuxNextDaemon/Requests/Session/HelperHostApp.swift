import Foundation

/// `helper-host-app`: the app socket's credentials for this app's own process (the host admits
/// that process only). The secret must never be logged or stored.
public struct HelperHostAppRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var socket: String
        public var secret: String
        public var hostPID: Int32

        enum CodingKeys: String, CodingKey {
            case socket, secret
            case hostPID = "host_pid"
        }
    }
    public static let command = "helper-host-app"
    public static var requiredCapability: String? { DaemonCapability.helperHost.rawValue }
    public init() {}
}
