public import Foundation

/// Supplies the Stack tokens for an authenticated `/api/vm` call.
///
/// Native calls send `Authorization: Bearer <access>` plus
/// `X-Stack-Refresh-Token: <refresh>`. Tokens arrive through closures so this
/// package needs no dependency on the auth package.
public struct CloudAPITokenSource: Sendable {
    /// A matching access and refresh token captured from one auth session.
    public typealias TokenPair = (accessToken: String, refreshToken: String)

    /// The current access token, or nil without a session.
    public var accessToken: @Sendable () async -> String?
    /// The current refresh token, or nil without a session.
    public var refreshToken: @Sendable () async -> String?
    /// The selected team context for team-owned Cloud machines, or nil for a
    /// personal account.
    public var teamID: @Sendable () async -> String?
    /// An optional coherent token-pair provider. When present, the Cloud
    /// service uses it instead of reading the two token closures separately.
    public var coherentTokenPair: (@Sendable () async -> TokenPair?)?

    /// Creates a token source from two async closures.
    public init(
        accessToken: @escaping @Sendable () async -> String?,
        refreshToken: @escaping @Sendable () async -> String?,
        teamID: @escaping @Sendable () async -> String? = { nil },
        coherentTokenPair: (@Sendable () async -> TokenPair?)? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.teamID = teamID
        self.coherentTokenPair = coherentTokenPair
    }

    /// A source that always yields the given pair; for tests and previews.
    public static func fixed(
        accessToken: String,
        refreshToken: String,
        teamID: String? = nil
    ) -> CloudAPITokenSource {
        CloudAPITokenSource(
            accessToken: { accessToken },
            refreshToken: { refreshToken },
            teamID: { teamID },
            coherentTokenPair: { (accessToken: accessToken, refreshToken: refreshToken) }
        )
    }
}
