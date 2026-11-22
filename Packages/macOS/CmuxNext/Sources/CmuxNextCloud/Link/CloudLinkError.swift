import Foundation

/// Why a Cloud link has no socket.
public enum CloudLinkError: Error, Equatable, Sendable {
    /// The link went down or its connection ended. v1 does not reconnect by
    /// itself: the user connects again.
    case disconnected(reason: String)
    /// The backend revoked the link.
    case revoked(reason: String)
    /// The answer named a socket that is not an owner-only socket of this user.
    case unsafeSocket(String)
    /// The answer is not an up carrier of the asked machine.
    case invalidAnswer(String)
    /// The op failed with the app server's error code.
    case failed(code: String, message: String)
    /// This resolver is not available yet.
    case unsupported
}

/// An app server op failure, as the daemon answered it (`error_code`).
public struct CloudAppOpError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
