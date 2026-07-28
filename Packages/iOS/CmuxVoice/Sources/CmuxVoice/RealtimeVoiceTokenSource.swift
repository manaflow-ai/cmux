/// Live Stack Auth token closures used by the Realtime credential provider.
public struct RealtimeVoiceTokenSource: Sendable {
    private let accessTokenProvider: @Sendable () async -> String?
    private let refreshTokenProvider: @Sendable () async -> String?

    /// Creates a token source.
    /// - Parameters:
    ///   - accessToken: Resolves the current Stack access token.
    ///   - refreshToken: Resolves the current Stack refresh token.
    public init(
        accessToken: @escaping @Sendable () async -> String?,
        refreshToken: @escaping @Sendable () async -> String?
    ) {
        self.accessTokenProvider = accessToken
        self.refreshTokenProvider = refreshToken
    }

    /// Resolve the current access token.
    public func accessToken() async -> String? {
        await accessTokenProvider()
    }

    /// Resolve the current refresh token.
    public func refreshToken() async -> String? {
        await refreshTokenProvider()
    }
}
