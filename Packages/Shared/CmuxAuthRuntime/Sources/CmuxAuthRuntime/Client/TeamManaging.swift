public import CMUXAuthCore
import Foundation

/// Team management beyond membership and selection: roles, one team's
/// detail, rename and delete. ``AuthCoordinator`` uses it when its
/// ``AuthClient`` also conforms; ``StackAuthClient`` does, through the cmux
/// team API when it has a cmux backend. Failures are ``CMUXTeamError``.
public protocol TeamManaging: Sendable {
    /// The user's teams with roles. Without a cmux backend the list comes
    /// from the sign-in service and every role is nil (unknown).
    func teamMemberships() async throws -> CMUXTeamMemberships
    /// One team's detail: the user's role, members, pending invitations, billing.
    func teamDetail(id: String) async throws -> CMUXTeamDetail
    /// Renames a team (admins only).
    func renameTeam(id: String, displayName: String) async throws -> CMUXAuthTeam
    /// Deletes a team (admins only; refused while it has a subscription).
    func deleteTeam(id: String) async throws
    /// Emails a team invitation to each address (`role` on joining).
    func inviteToTeam(id: String, emails: [String], role: CMUXTeamRole) async throws -> CMUXTeamInviteResult
}

extension StackAuthClient: TeamManaging {
    /// The cmux team API over this client's session, or nil with no cmux backend.
    var teamsAPI: CmuxTeamsAPI? {
        guard let apiBaseURL else { return nil }
        let stack = stack
        return CmuxTeamsAPI(baseURL: apiBaseURL) {
            guard let access = await stack.getAccessToken(), let refresh = await stack.getRefreshToken() else { return nil }
            return (access, refresh)
        }
    }

    public func teamMemberships() async throws -> CMUXTeamMemberships {
        if let teamsAPI { return try await teamsAPI.memberships() }
        async let teams = listTeams()
        async let selected: String? = try? await selectedTeamID()
        return CMUXTeamMemberships(teams: try await teams.map(CMUXTeamMembership.init(team:)), selectedTeamID: await selected)
    }

    public func teamDetail(id: String) async throws -> CMUXTeamDetail {
        guard let teamsAPI else { throw CMUXTeamError.unavailable }
        return try await teamsAPI.detail(teamID: id)
    }

    public func renameTeam(id: String, displayName: String) async throws -> CMUXAuthTeam {
        guard let teamsAPI else { throw CMUXTeamError.unavailable }
        return try await teamsAPI.rename(teamID: id, displayName: displayName)
    }

    public func deleteTeam(id: String) async throws {
        guard let teamsAPI else { throw CMUXTeamError.unavailable }
        try await teamsAPI.delete(teamID: id)
    }

    public func inviteToTeam(id: String, emails: [String], role: CMUXTeamRole) async throws -> CMUXTeamInviteResult {
        guard let teamsAPI else { throw CMUXTeamError.unavailable }
        return try await teamsAPI.invite(teamID: id, emails: emails, role: role)
    }
}
