import CmuxCloud
import CmuxAuthRuntime
import CmuxSettingsUI
import Foundation

/// Failures of the members-and-invites actions that are not API refusals.
enum TeamMembersFlowError: Error, Equatable {
    /// No team is selected and the caller named none.
    case noTeam
    /// The signed-in user has no identity yet.
    case signedOut
}

extension HostAccountFlow {
    /// The team a members action applies to: an explicit id from the CLI or
    /// socket, otherwise the confirmed (not pending) active team.
    func teamIDForMembersAction(_ explicit: String?) throws -> String {
        let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        guard let confirmedTeamID, !confirmedTeamID.isEmpty else { throw TeamMembersFlowError.noTeam }
        return confirmedTeamID
    }

    /// Roster, pending invitations, links and seat usage for one team.
    func loadTeamDetail(teamID: String? = nil) async throws -> CloudTeamDetail {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.detail(teamID: id)
    }

    /// Invite by email. The server sends the email and stores the role.
    func inviteTeamMembers(
        teamID: String? = nil,
        emails: [String],
        role: CloudTeamRole
    ) async throws -> CloudTeamInviteResult {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.invite(teamID: id, emails: emails, role: role)
    }

    /// A reusable member-only invite link. The URL is shown once.
    func createTeamInviteLink(
        teamID: String? = nil,
        expiresInDays: Int?,
        maxUses: Int?
    ) async throws -> CloudTeamInviteLinkCreated {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.createInviteLink(teamID: id, expiresInDays: expiresInDays, maxUses: maxUses)
    }

    func revokeTeamInvitation(teamID: String? = nil, invitationID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        try await TeamsClient.shared.revokeInvitation(teamID: id, invitationID: invitationID)
    }

    func revokeTeamInviteLink(teamID: String? = nil, linkID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        try await TeamsClient.shared.revokeInviteLink(teamID: id, linkID: linkID)
    }

    /// Remove a member, or leave the team when `userID` is the caller. Leaving
    /// refreshes membership so the picker and Cloud scope drop the team.
    func removeTeamMember(teamID: String? = nil, userID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        try await TeamsClient.shared.removeMember(teamID: id, userID: userID)
        if userID == coordinator.currentUser?.id {
            await coordinator.refreshTeams()
        }
    }

    func changeTeamMemberRole(teamID: String? = nil, userID: String, role: CloudTeamRole) async throws -> CloudTeamMember {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.changeMemberRole(teamID: id, userID: userID, role: role)
    }

    /// ``AccountFlow`` hook used by the Settings Account card.
    func openTeamMembers() {
        showTeamMembers(focusInvite: false)
    }

    /// Opens (or fronts) the members-and-invites window for the active team.
    /// Shared by the Cloud team picker, Settings, the palette and the socket.
    func showTeamMembers(focusInvite: Bool) {
        guard isAuthenticated, confirmedTeamID != nil else { return }
        let controller = teamMembersWindowController ?? CloudTeamMembersWindowController(accountFlow: self) { [weak self] in
            self?.teamMembersWindowController = nil
        }
        teamMembersWindowController = controller
        controller.show(focusInvite: focusInvite)
    }

    /// One user-facing sentence per failure, shared by every entrypoint.
    nonisolated static func teamMembersUserMessage(_ error: Error) -> String {
        switch error {
        case TeamMembersFlowError.noTeam:
            return String(localized: "teamMembers.error.noTeam", defaultValue: "Select a team first.")
        case TeamMembersFlowError.signedOut, TeamsClientError.notSignedIn, AuthError.unauthorized:
            return String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
        case TeamsClientError.invalidEmail:
            return String(localized: "teamMembers.error.invalidEmail", defaultValue: "Enter at least one email address.")
        case TeamsClientError.invalidLinkOptions:
            return String(localized: "teamMembers.error.invalidLinkOptions", defaultValue: "Link expiry must be 1, 7 or 30 days and max uses at least 1.")
        case TeamsClientError.backendUnreachable, TeamsClientError.sessionRefreshFailed:
            return String(localized: "teamMembers.error.offline", defaultValue: "cmux Cloud is unreachable. Check your connection and try again.")
        case let TeamsClientError.api(code, _, message):
            return Self.teamAPIMessage(code: code, fallback: message)
        default:
            return String(localized: "socket.authTeam.failed", defaultValue: "Could not update the team. Try again.")
        }
    }

    private nonisolated static func teamAPIMessage(code: String, fallback: String) -> String {
        switch code {
        case "seat_limit":
            return String(localized: "teamMembers.error.seatLimit", defaultValue: "This plan includes 3 members. Remove someone or upgrade to Team to invite more.")
        case "forbidden", "team_not_found":
            return String(localized: "teamMembers.error.forbidden", defaultValue: "Only team admins can do that.")
        case "last_admin":
            return String(localized: "teamMembers.error.lastAdmin", defaultValue: "A team must keep at least one admin.")
        case "member_not_found":
            return String(localized: "teamMembers.error.memberNotFound", defaultValue: "That person is not a member of this team.")
        case "invitation_not_found":
            return String(localized: "teamMembers.error.invitationNotFound", defaultValue: "That invitation no longer exists.")
        case "rate_limited":
            return String(localized: "teamMembers.error.rateLimited", defaultValue: "Too many invitations. Wait a minute and try again.")
        case "unauthorized":
            return String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
        default:
            return fallback.isEmpty
                ? String(localized: "socket.authTeam.failed", defaultValue: "Could not update the team. Try again.")
                : fallback
        }
    }
}
