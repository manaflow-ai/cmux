import Foundation

/// Errors surfaced by the RFB client.
public enum RFBError: Error, Equatable, Sendable {
    /// The peer closed the connection (or it dropped) before enough bytes arrived.
    case connectionClosed
    /// The underlying transport reported a failure.
    case transport(String)
    /// The server announced a protocol version we cannot speak.
    case unsupportedProtocolVersion(String)
    /// The server offered no security type we support.
    case noSupportedSecurityType([UInt8])
    /// VNC authentication failed (bad password) or the security handshake was rejected.
    case authenticationFailed(String)
    /// A server message did not conform to the protocol.
    case protocolViolation(String)
    /// A password was required but none was supplied.
    case passwordRequired
    /// The server requires Apple authentication, which needs both a user name
    /// and password (e.g. `vnc://user:password@host`).
    case credentialsRequired
}

extension RFBError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "The connection closed."
        case .transport(let message):
            return message
        case .unsupportedProtocolVersion(let version):
            return "Unsupported RFB protocol version: \(version)"
        case .noSupportedSecurityType:
            return "The server offered no supported authentication method."
        case .authenticationFailed(let reason):
            return reason.isEmpty ? "Authentication failed." : reason
        case .protocolViolation(let detail):
            return "Protocol error: \(detail)"
        case .passwordRequired:
            return "A password is required to connect."
        case .credentialsRequired:
            return "This server requires a user name and password (vnc://user:password@host)."
        }
    }
}
