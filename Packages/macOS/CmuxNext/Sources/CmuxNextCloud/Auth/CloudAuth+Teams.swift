public import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// Team management for Settings > Accounts, through the coordinator so the
/// team list, the active team and everything that follows the team change
/// together. Every failure is a `CMUXTeamError` (a session that ended
/// mid-change is `signedOut`, another team change still running is `busy`).
extension CloudAuth {
    public func teamMemberships() async throws -> CMUXTeamMemberships {
        try await Self.teamErrors { try await coordinator.teamMemberships() }
    }

    public func teamDetail(id: String) async throws -> CMUXTeamDetail {
        try await Self.teamErrors { try await coordinator.teamDetail(id: id) }
    }

    /// Creates a team and makes it the active team.
    public func createTeam(named name: String) async throws -> CMUXAuthTeam {
        let valid = try CMUXTeamName(name).value
        return try await Self.teamErrors { try await coordinator.createTeam(displayName: valid) }
    }

    public func renameTeam(id: String, to name: String) async throws {
        try await Self.teamErrors { try await coordinator.renameTeam(id: id, displayName: name) }
    }

    /// Deletes a team; when it was the active team, another becomes active.
    public func deleteTeam(id: String) async throws {
        try await Self.teamErrors { try await coordinator.deleteTeam(id: id) }
    }

    /// Emails a team invitation to each address, as a member on joining.
    public func inviteToTeam(id: String, emails: [String]) async throws -> CMUXTeamInviteResult {
        try await Self.teamErrors { try await coordinator.inviteToTeam(id: id, emails: emails, role: .member) }
    }

    /// Invites one address as a member and says how it went (Home's Invite to Team).
    ///
    /// - Parameters:
    ///   - email: The address, already validated.
    ///   - teamID: The team.
    /// - Returns: The answer; never throws.
    public func inviteOne(_ email: String, toTeam teamID: String) async -> CloudTeamInviteAnswer {
        do {
            let result = try await inviteToTeam(id: teamID, emails: [email])
            guard let failure = result.failed.first else { return .sent }
            return failure.isAlreadyMember ? .alreadyMember : .sendFailed
        } catch CMUXTeamError.forbidden {
            return .notAllowed
        } catch {
            return .unreachable
        }
    }

    /// What the team's plan says about one more member; nil when the detail cannot be read.
    public func seatFacts(teamID: String) async -> CloudTeamSeatFacts? {
        guard let detail = try? await teamDetail(id: teamID) else { return nil }
        let billing = detail.billing
        return CloudTeamSeatFacts(canInvite: detail.viewer.permissions.inviteMembers || detail.viewer.role == .admin,
                                  planID: billing?.planId, hasSubscription: billing?.hasActiveSubscription ?? false,
                                  memberCount: billing?.memberCount ?? detail.members.count, memberLimit: billing?.memberLimit)
    }

    private static func teamErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is AuthTeamChangeInProgressError {
            throw CMUXTeamError.busy
        } catch AuthError.unauthorized {
            throw CMUXTeamError.signedOut
        }
    }
}
