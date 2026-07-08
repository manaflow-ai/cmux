import Foundation
public import StackAuth

/// The token-store seam for hosts that seed tokens out-of-band: StackAuth's
/// `TokenStoreProtocol` plus the seeding/snapshot operations the macOS
/// hosted-browser sign-in flow needs.
///
/// The browser callback delivers tokens out-of-band (not through a Stack SDK
/// sign-in call), so the flow seeds them directly into the store the
/// `StackClientApp` was built over, and clears them with a compare-style guard
/// so a racing sign-in's fresh tokens are never wiped by a stale sign-out.
public protocol StackAuthTokenStoreProtocol: TokenStoreProtocol, Sendable {
    /// Store a freshly delivered token pair.
    func seed(accessToken: String, refreshToken: String) async
    /// Clear both tokens unconditionally.
    func clear() async
    /// The currently stored access token, if any.
    func currentAccessToken() async -> String?
    /// The currently stored refresh token, if any.
    func currentRefreshToken() async -> String?
    /// Clear the stored tokens only when they still match the expected pair.
    /// - Returns: Whether the tokens were cleared.
    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool
}

extension StackAuthTokenStoreProtocol {
    public func seed(accessToken: String, refreshToken: String) async {
        await setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func clear() async {
        await clearTokens()
    }

    public func currentAccessToken() async -> String? {
        await getStoredAccessToken()
    }

    public func currentRefreshToken() async -> String? {
        await getStoredRefreshToken()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let snapshot = AuthTokenSnapshot(
            accessToken: await currentAccessToken(),
            refreshToken: await currentRefreshToken()
        )
        guard snapshot.matches(expectedAccessToken: accessToken, expectedRefreshToken: refreshToken) else {
            return false
        }
        await clear()
        return true
    }
}
