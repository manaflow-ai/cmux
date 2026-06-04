import Foundation
import StackAuth

/// The macOS token-store seam: StackAuth's `TokenStoreProtocol` plus the
/// seeding/snapshot operations the hosted-browser sign-in flow needs.
///
/// The browser callback delivers tokens out-of-band (not through a Stack SDK
/// sign-in call), so the flow seeds them directly into the store the
/// `StackClientApp` was built over, and clears them with a compare-style guard
/// so a racing sign-in's fresh tokens are never wiped by a stale sign-out.
protocol StackAuthTokenStoreProtocol: TokenStoreProtocol, Sendable {
    func seed(accessToken: String, refreshToken: String) async
    func clear() async
    func currentAccessToken() async -> String?
    func currentRefreshToken() async -> String?
    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool
}

extension StackAuthTokenStoreProtocol {
    func seed(accessToken: String, refreshToken: String) async {
        await setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    func clear() async {
        await clearTokens()
    }

    func currentAccessToken() async -> String? {
        await getStoredAccessToken()
    }

    func currentRefreshToken() async -> String? {
        await getStoredRefreshToken()
    }

    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
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
