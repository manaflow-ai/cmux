import Foundation

/// The token pair carried by a cmux auth callback URL
/// (`cmux://auth-callback?stack_refresh=…&stack_access=…`).
public struct AuthCallbackPayload: Equatable, Sendable {
    /// The Stack refresh token from the callback.
    public let refreshToken: String
    /// The Stack access token from the callback.
    public let accessToken: String

    /// Creates a payload from its parts.
    public init(refreshToken: String, accessToken: String) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
    }
}
