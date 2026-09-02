public import Foundation

/// Supplies the Stack tokens for an authenticated `/api/vm` call.
///
/// Native calls send `Authorization: Bearer <access>` plus
/// `X-Stack-Refresh-Token: <refresh>`. Tokens arrive through closures so this
/// package needs no dependency on the auth package.
public struct CloudAPITokenSource: Sendable {
    /// The current access token, or nil without a session.
    public var accessToken: @Sendable () async -> String?
    /// The current refresh token, or nil without a session.
    public var refreshToken: @Sendable () async -> String?

    /// Creates a token source from two async closures.
    public init(
        accessToken: @escaping @Sendable () async -> String?,
        refreshToken: @escaping @Sendable () async -> String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// A source that always yields the given pair; for tests and previews.
    public static func fixed(accessToken: String, refreshToken: String) -> CloudAPITokenSource {
        CloudAPITokenSource(accessToken: { accessToken }, refreshToken: { refreshToken })
    }
}
