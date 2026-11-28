public import Foundation

/// A short-lived private route for an SCP transfer. The private key remains
/// on the caller; only its public half is sent to the backend.
public struct CloudSCPEndpoint: Sendable, Hashable, Decodable {
    public var host: String
    public var port: Int
    public var username: String
    public var hostPublicKey: String
    public var expiresAtUnix: Int64

    enum CodingKeys: String, CodingKey { case host, port, username, hostPublicKey, hostPublicKeySnake = "host_public_key", expiresAtUnix, expiresAtUnixSnake = "expires_at_unix" }

    public init(host: String, port: Int, username: String, hostPublicKey: String, expiresAtUnix: Int64) {
        self.host = host
        self.port = port
        self.username = username
        self.hostPublicKey = hostPublicKey
        self.expiresAtUnix = expiresAtUnix
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        hostPublicKey = try c.decodeIfPresent(String.self, forKey: .hostPublicKey)
            ?? c.decode(String.self, forKey: .hostPublicKeySnake)
        expiresAtUnix = try c.decodeIfPresent(Int64.self, forKey: .expiresAtUnix)
            ?? c.decode(Int64.self, forKey: .expiresAtUnixSnake)
    }
}
