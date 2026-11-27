import Foundation

extension CloudAuth {
    /// Team names and backend scopes from the existing Rust identity rules.
    public var shareTeams: [(id: String, name: String)] {
        guard isSignedIn else { return [] }
        return activeTeam.rows.compactMap { row in
            guard let id = try? CloudAccessToken.team(requested: nil, activeStackTeam: row.id,
                                                      managedStackTeam: managedTeamID,
                                                      stackProjectID: configuration.stackProjectID) else { return nil }
            return (id: id, name: row.title)
        }
    }

    /// Bind the room's install to the restored account before minting its scoped token.
    /// A changed account or membership never hands a token back to an old consent.
    public func shareOwnerToken(installs: ShareInstalls, api: URL?, team: String?, accountScope: String?) async throws -> String? {
        guard let stackUser = await restoredUserID(), managedTeamID == nil || teamID != nil else { return nil }
        if let accountScope, accountKey != accountScope { return nil }
        let scope = accountKey
        let share = await installs.identity(for: api)
        try await share.signedIn(stackUser: stackUser, session: { try await self.tokens().access })
        let token: String
        if let team {
            guard shareTeams.contains(where: { $0.id == team }), try accessTokenTeam(requested: team) == team else { return nil }
            token = try await share.installToken(team: team)
        } else { token = try await share.installToken() }
        guard user?.id == stackUser, accountKey == scope else { return nil }
        if let team, !shareTeams.contains(where: { $0.id == team }) { return nil }
        return token
    }
}
