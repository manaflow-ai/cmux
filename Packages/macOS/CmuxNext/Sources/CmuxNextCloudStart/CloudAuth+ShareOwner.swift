public import CmuxNextCloud
public import Foundation
import os

/// A shared chat's owner token and the teams it can be shared with. The rules are Rust's (cmux-cloud-config
/// `identity::share_teams` and `share_team_allowed`, with their tests; op `cloud_identity_share_teams`). Here they are
/// only asked, before and after the asynchronous mint, so a changed account or membership never hands a token
/// back to an old consent.
extension CloudAuth {
    /// The teams a chat can be shared with: `(id, name)`, the id a backend team id. Empty signed out.
    public var shareTeams: [(id: String, name: String)] { shareTeamRules(requested: nil)?.teams.map { ($0.id, $0.name) } ?? [] }

    /// A guest link's owner token from `api` (nil: the build's default), registering that install first when sign-in
    /// did not. With `team`, a token scoped to it, only while Rust allows that team; with `accountScope`, only while
    /// ``accountKey`` is still that one. Nil signed out, switched, or with no team on a managed device.
    public func shareOwnerToken(installs: ShareInstalls, api: URL?, team: String?, accountScope: String?) async -> String? {
        guard let stackUser = await restoredUserID(), managedTeamID == nil || teamID != nil else { return nil }
        let scope = accountKey
        if let accountScope, scope != accountScope { return nil }
        let unchanged = { self.user?.id == stackUser && self.accountKey == scope && (team.map { self.shareTeamRules(requested: $0)?.allowed == true } ?? true) }
        let share = await installs.identity(for: api)
        guard unchanged() else { return nil }
        do {
            try await share.signedIn(stackUser: stackUser, session: { try await self.tokens().access })
            guard unchanged() else { return nil }
            let token = if let team { try await share.installToken(team: team) } else { try await share.installToken() }
            return unchanged() ? token : nil // an account switch meanwhile: not the old account's token
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud").error("share owner token failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private struct ShareTeamRules: Decodable {
        struct Team: Decodable { var id: String, name: String }
        var teams: [Team], allowed: Bool?
    }

    private func shareTeamRules(requested: String?) -> ShareTeamRules? {
        struct Row: Encodable { var id: String, title: String }
        struct Request: Encodable {
            var signedIn: Bool, rows: [Row], requested: String?, activeStackTeam: String?, managedStackTeam: String?, stackProjectId: String
        }
        let request = Request(signedIn: isSignedIn, rows: activeTeam.rows.map { Row(id: $0.id, title: $0.title) }, requested: requested,
                              activeStackTeam: teamID, managedStackTeam: managedTeamID, stackProjectId: configuration.stackProjectID)
        return CloudStartCore().call("cloud_identity_share_teams", request, as: ShareTeamRules.self)
    }
}
