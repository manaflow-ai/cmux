import Foundation

/// Why an RFB session failed. Apps map these to their own localized copy;
/// `description` is for logs only.
public enum RFBError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The TCP connection failed or dropped (the system's message).
    case transport(String)
    /// The server closed the stream.
    case connectionClosed
    /// The server spoke something other than RFB 3.3, 3.7 or 3.8.
    case unsupportedProtocolVersion(String)
    /// The server offered no security type this client implements.
    case noSupportedSecurityType([UInt8])
    /// The server needs a password (VNC authentication) and none was given.
    case passwordRequired
    /// The server needs a user name and password (macOS Screen Sharing).
    case credentialsRequired
    /// The server refused the credentials or the connection (its reason).
    case authenticationFailed(String)
    /// The server sent bytes that break the protocol.
    case protocolViolation(String)

    public var description: String {
        switch self {
        case let .transport(message): "transport: \(message)"
        case .connectionClosed: "connection closed"
        case let .unsupportedProtocolVersion(version): "unsupported protocol \(version)"
        case let .noSupportedSecurityType(types): "no supported security type in \(types)"
        case .passwordRequired: "password required"
        case .credentialsRequired: "user name and password required"
        case let .authenticationFailed(reason): "authentication failed: \(reason)"
        case let .protocolViolation(detail): "protocol violation: \(detail)"
        }
    }

    /// True when new credentials could fix it (the app asks again).
    public var needsCredentials: Bool {
        switch self {
        case .passwordRequired, .credentialsRequired, .authenticationFailed: true
        default: false
        }
    }
}
