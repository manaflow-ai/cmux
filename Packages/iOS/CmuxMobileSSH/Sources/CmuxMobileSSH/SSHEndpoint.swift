import Foundation
import NIOSSH

/// Where an SSH connection goes and who it logs in as.
public struct SSHEndpoint: Hashable, Sendable, Codable {
    /// DNS name, IPv4, or IPv6 literal.
    public var host: String
    /// TCP port, 22 by default.
    public var port: Int
    /// Remote login name.
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// The `known_hosts`-style identity used to pin a host key: `host` for port 22,
    /// `[host]:port` otherwise, matching OpenSSH.
    public var hostKeyIdentity: String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }
}

/// One way to prove the user's identity to a server, tried in order.
public enum SSHCredential: Sendable {
    /// A private key held in memory or the Secure Enclave.
    case privateKey(NIOSSHPrivateKey)
    /// A password. Only used once to install a key (PRD D16); never persisted.
    case password(String)
}

/// Errors surfaced by ``SSHConnection``.
public enum SSHConnectionError: Error, Equatable, Sendable {
    /// The server's identity key did not pass the host key policy.
    case hostKeyRejected(SSHHostKeyVerdict)
    /// The server rejected every offered credential.
    case authenticationFailed
    /// A channel could not be opened, or opened with an unexpected type.
    case channelOpenFailed(String)
    /// The server refused a channel request (pty, shell, exec, subsystem).
    case channelRequestRejected(String)
    /// The connection closed.
    case closed
}
