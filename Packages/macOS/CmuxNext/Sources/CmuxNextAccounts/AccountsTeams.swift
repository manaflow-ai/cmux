public import CMUXAuthCore
public import CmuxNextCloud
import Foundation
import Observation

/// The demo account's teams for ``MockAccountsServices``: Personal (active,
/// the person is its admin) and Acme (the person is a member). Answers like
/// the cmux team API: create makes the person admin, rename and delete need
/// admin, and a team with a subscription cannot be deleted.
@MainActor @Observable
final class MockTeamSource: ActiveTeamSource {
    var isAuthenticated = true
    var availableTeams = [CMUXAuthTeam(id: "team-personal", displayName: "Personal"), CMUXAuthTeam(id: "team-acme", displayName: "Acme")]
    var selectedTeamID: String? = "team-personal"
    var failure: (any Error)?
    /// What the next team-management call throws, if anything.
    var managementFailure: (any Error)?
    /// Teams the person administers; the others they are a member of.
    var adminTeams: Set<String> = ["team-personal"]
    /// Teams with an active subscription (delete is refused).
    var subscribedTeams: Set<String> = []
    /// Member teams whose members may still invite and edit (the sign-in service's
    /// default member permissions): the server refuses rename and delete to any non-admin.
    var permissiveMemberTeams: Set<String> = []
    @ObservationIgnored private var created = 0

    var resolvedTeamID: String? { selectedTeamID ?? availableTeams.first?.id }

    func selectTeam(id: String?) async throws {
        if let failure { throw failure }
        selectedTeamID = id
    }

    func refreshTeams() async {}

    var memberships: CMUXTeamMemberships {
        CMUXTeamMemberships(teams: availableTeams.map { team in
            let admin = adminTeams.contains(team.id)
            return CMUXTeamMembership(id: team.id, displayName: team.displayName, role: admin ? .admin : .member,
                                      permissions: admin ? Self.adminPermissions : CMUXTeamPermissions(readMembers: true))
        }, selectedTeamID: selectedTeamID)
    }

    func detail(id: String) throws -> CMUXTeamDetail {
        if let managementFailure { throw managementFailure }
        guard let team = availableTeams.first(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        let admin = adminTeams.contains(id)
        let you = CMUXTeamDetail.Member(userId: "user-you", displayName: "Demo User", email: "demo@example.com",
                                        role: admin ? .admin : .member, isViewer: true)
        let others = id == "team-acme"
            ? [CMUXTeamDetail.Member(userId: "user-ada", displayName: "Ada Lovelace", email: "ada@example.com", role: .admin, isViewer: false)]
            : []
        let invitations = admin
            ? [CMUXTeamDetail.Invitation(id: "invite-1", email: "grace@example.com", role: .member, expiresAt: "2026-11-02T10:00:00.000Z")]
            : []
        let members = [you] + others
        return CMUXTeamDetail(
            team: .init(id: id, displayName: team.displayName),
            viewer: .init(userId: "user-you", role: admin ? .admin : .member,
                          permissions: admin || permissiveMemberTeams.contains(id)
                              ? Self.adminPermissions : CMUXTeamPermissions(readMembers: true)),
            members: members, invitations: invitations,
            billing: .init(planId: subscribedTeams.contains(id) ? "team" : nil, seats: nil, memberLimit: nil,
                           memberCount: members.count, hasActiveSubscription: subscribedTeams.contains(id)))
    }

    func create(_ name: String) throws -> CMUXAuthTeam {
        if let managementFailure { throw managementFailure }
        let name = try CMUXTeamName(name)
        created += 1
        let team = CMUXAuthTeam(id: "team-new-\(created)", displayName: name.value)
        availableTeams.append(team)
        adminTeams.insert(team.id)
        selectedTeamID = team.id
        return team
    }

    func rename(_ id: String, to name: String) throws {
        if let managementFailure { throw managementFailure }
        let name = try CMUXTeamName(name)
        guard let index = availableTeams.firstIndex(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        guard adminTeams.contains(id) else { throw CMUXTeamError.forbidden }
        availableTeams[index] = CMUXAuthTeam(id: id, displayName: name.value)
    }

    func delete(_ id: String) throws {
        if let managementFailure { throw managementFailure }
        guard availableTeams.contains(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        guard adminTeams.contains(id) else { throw CMUXTeamError.forbidden }
        guard !subscribedTeams.contains(id) else { throw CMUXTeamError.subscriptionActive }
        availableTeams.removeAll { $0.id == id }
        if selectedTeamID == id { selectedTeamID = availableTeams.first?.id }
    }

    private static let adminPermissions = CMUXTeamPermissions(updateTeam: true, deleteTeam: true, inviteMembers: true, readMembers: true,
                                                             removeMembers: true, manageApiKeys: true, manageBilling: true)
}
