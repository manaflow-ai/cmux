import Foundation

/// The Stack access and refresh tokens for one authenticated billing call.
public struct BillingAPICredentials: Sendable, Equatable {
    /// The Stack access token, sent as `Authorization: Bearer`.
    public let accessToken: String
    /// The Stack refresh token, sent as `X-Stack-Refresh-Token`.
    public let refreshToken: String

    /// Creates a credential pair.
    /// - Parameters:
    ///   - accessToken: The Stack access token.
    ///   - refreshToken: The Stack refresh token.
    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}
