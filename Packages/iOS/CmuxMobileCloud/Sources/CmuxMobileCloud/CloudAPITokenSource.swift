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

    /// Reads credentials and their selected team routing from one auth
    /// snapshot. Returns nil when there is no session, and throws when the
    /// session exists but its credentials cannot be read right now, so a
    /// transient state is never mistaken for a sign-out.
    public var coherentTokenContext: @Sendable () async throws -> TokenContext?

    /// Creates a token source from one coherent live auth snapshot.
    public init(
        coherentTokenContext: @escaping @Sendable () async throws -> TokenContext?
    ) {
        self.coherentTokenContext = coherentTokenContext
    }

    /// Creates a token source for callers that do not need team routing.
    public init(
        coherentTokenPair: @escaping @Sendable () async throws -> TokenPair?
    ) {
        self.coherentTokenContext = {
            guard let pair = try await coherentTokenPair() else { return nil }
            return TokenContext(
                accessToken: pair.accessToken,
                refreshToken: pair.refreshToken
            )
        }
    }

    /// A source that always yields the given pair; for tests and previews.
    public static func fixed(
        accessToken: String,
        refreshToken: String,
        teamID: String? = nil
    ) -> CloudAPITokenSource {
        CloudAPITokenSource(
            coherentTokenContext: {
                TokenContext(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    teamID: teamID
                )
            }
        )
    }
}
