public import Foundation

/// Supplies the Stack tokens for an authenticated `/api/vm` call.
///
/// Native calls send `Authorization: Bearer <access>` plus
/// `X-Stack-Refresh-Token: <refresh>`. Tokens arrive through closures so this
/// package needs no dependency on the auth package.
public struct CloudAPITokenSource: Sendable {
    /// A matching access and refresh token captured from one auth session.
    public typealias TokenPair = (accessToken: String, refreshToken: String)

    /// Credentials and team routing captured from one auth session.
    public struct TokenContext: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String
        public let teamID: String?

        public init(accessToken: String, refreshToken: String, teamID: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.teamID = teamID
        }
    }

    /// The selected team context for team-owned Cloud machines, or nil for a
    /// personal account.
    public var teamID: @Sendable () async -> String?
    /// Reads a matching access and refresh token from one auth snapshot.
    /// Returns nil when there is no session, and throws when the session exists
    /// but its tokens cannot be read right now, so a transient state is never
    /// mistaken for a sign-out.
    public var coherentTokenPair: @Sendable () async throws -> TokenPair?

    /// Creates a token source from one coherent live auth snapshot, optionally
    /// including the selected team.
    public init(
        coherentTokenPair: @escaping @Sendable () async throws -> TokenPair?,
        teamID: @escaping @Sendable () async -> String? = { nil }
    ) {
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
            coherentTokenPair: { (accessToken: accessToken, refreshToken: refreshToken) },
            teamID: { teamID }
        )
    }
}
