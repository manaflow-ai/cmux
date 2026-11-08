import Foundation

/// A short-lived private route for an SCP transfer, as cmux-cloud-machine
/// `models::read("scp_endpoint")` answers it. The private key remains on the caller; only its
/// public half is sent to the backend.
public struct CloudSCPEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int
    public var username: String
    public var hostPublicKey: String
    public var expiresAtUnix: Int64

    public init(host: String, port: Int, username: String, hostPublicKey: String, expiresAtUnix: Int64) {
        self.host = host
        self.port = port
        self.username = username
        self.hostPublicKey = hostPublicKey
        self.expiresAtUnix = expiresAtUnix
    }
}
