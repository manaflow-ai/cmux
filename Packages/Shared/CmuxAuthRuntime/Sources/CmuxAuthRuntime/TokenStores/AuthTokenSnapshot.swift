import Foundation

/// A point-in-time copy of the stored token pair, used to guard "clear only if
/// nothing changed since I looked" operations against racing sign-ins.
struct AuthTokenSnapshot: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?

    /// Whether the snapshot still matches the expected tokens. When an
    /// expected refresh token is present it is the identity that matters (the
    /// access token rotates underneath it); without one, both stored values
    /// must match.
    func matches(expectedAccessToken: String?, expectedRefreshToken: String?) -> Bool {
        if let expectedRefreshToken {
            return refreshToken == expectedRefreshToken
        }
        return refreshToken == nil && accessToken == expectedAccessToken
    }
}
