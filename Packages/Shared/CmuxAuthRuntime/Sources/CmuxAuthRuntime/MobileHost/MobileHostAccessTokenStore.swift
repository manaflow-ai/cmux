public import StackAuth

/// A single-token, in-memory ``TokenStoreProtocol`` for the mobile host's Stack
/// verification path.
///
/// ``MobileHostStackAuthVerifier`` builds one short-lived `StackClientApp` per
/// cache-miss verification, seeded with exactly the access token the mobile
/// client presented. There is no refresh token and no persistence: the client
/// owns its own credential lifecycle, and this Mac only needs to ask Stack "who
/// does this access token belong to". So `getStoredRefreshToken` returns `nil`,
/// `clearTokens` drops the access token, and the compare-and-set / refresh hooks
/// only ever update the access token (the refresh-token arguments are ignored
/// because none is held). Lifted byte-faithfully from the `private actor`
/// previously nested in `MobileHostService.swift`.
public actor MobileHostAccessTokenStore: TokenStoreProtocol {
    private var accessToken: String?

    /// Seeds the store with the access token to verify.
    public init(accessToken: String) {
        self.accessToken = accessToken
    }

    public func getStoredAccessToken() async -> String? {
        accessToken
    }

    public func getStoredRefreshToken() async -> String? {
        nil
    }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        if let accessToken {
            self.accessToken = accessToken
        }
    }

    public func clearTokens() async {
        accessToken = nil
    }

    public func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        if let newAccessToken {
            accessToken = newAccessToken
        }
    }
}
