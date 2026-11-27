import AppKit
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

// MARK: - Cloud client path (socket, CLI and Settings share it)

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
    func cloudTeamDetail(teamID: String? = nil) async throws -> CloudTeamDetail {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.detail(teamID: id)
    }

    /// Invite by email. The server sends the email and stores the role.
    func cloudInviteTeamMembers(
        teamID: String? = nil,
        emails: [String],
        role: CloudTeamRole
    ) async throws -> CloudTeamInviteResult {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.invite(teamID: id, emails: emails, role: role)
    }

    /// A reusable member-only invite link. The URL is shown once.
    func cloudCreateTeamInviteLink(
        teamID: String? = nil,
        expiresInDays: Int?,
        maxUses: Int?
    ) async throws -> CloudTeamInviteLinkCreated {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.createInviteLink(teamID: id, expiresInDays: expiresInDays, maxUses: maxUses)
    }

    func cloudRevokeTeamInvitation(teamID: String? = nil, invitationID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        try await TeamsClient.shared.revokeInvitation(teamID: id, invitationID: invitationID)
    }

    func cloudRevokeTeamInviteLink(teamID: String? = nil, linkID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        try await TeamsClient.shared.revokeInviteLink(teamID: id, linkID: linkID)
    }

    /// Remove a member, or leave the team when `userID` is the caller. Leaving
    /// refreshes membership so the picker and Cloud scope drop the team.
    func cloudRemoveTeamMember(teamID: String? = nil, userID: String) async throws {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        try await TeamsClient.shared.removeMember(teamID: id, userID: userID)
        if userID == coordinator.currentUser?.id {
            await coordinator.refreshTeams()
        }
    }

    func cloudChangeTeamMemberRole(teamID: String? = nil, userID: String, role: CloudTeamRole) async throws -> CloudTeamMember {
        guard isAuthenticated else { throw TeamMembersFlowError.signedOut }
        let id = try teamIDForMembersAction(teamID)
        return try await TeamsClient.shared.changeMemberRole(teamID: id, userID: userID, role: role)
    }

    /// Opens the Invite popover on the Cloud header. Shared by the picker
    /// row, the palette and the socket.
    func showTeamInvite(preferredWindow: NSWindow? = nil) {
        guard isAuthenticated, confirmedTeamID != nil else { return }
        _ = AppDelegate.shared?.openCloudTeamInvite(preferredWindow: preferredWindow, debugSource: "accountFlow.showTeamInvite")
    }

    /// Opens Settings › Account at the Team card (roster, roles, pending
    /// invitations and links). `focusInvite` expands the inline composer.
    func showTeamMembers(focusInvite: Bool) {
        guard isAuthenticated, confirmedTeamID != nil else { return }
        SettingsWindowPresenter.show(navigationTarget: .account)
        SettingsNavigationRequest.post(.account, anchorID: AccountTeamCard.searchAnchorID, highlight: !focusInvite)
        if focusInvite {
            NotificationCenter.default.post(name: AccountTeamCard.focusInviteRequestName, object: nil)
        }
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
        case TeamsClientError.backendUnreachable:
            return String(localized: "teamMembers.error.offline", defaultValue: "cmux Cloud is unreachable. Check your connection and try again.")
        case TeamsClientError.sessionRefreshFailed:
            // The token read failed before any request left the Mac: a sign-in
            // or sign-out still owned the session, or the token refresh failed.
            return String(localized: "teamMembers.error.sessionRefresh", defaultValue: "Could not confirm your cmux sign-in. Try again in a moment.")
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

// MARK: - Settings Team card (AccountTeamManagement)

extension HostAccountFlow {
    var supportsTeamManagement: Bool { CloudMachinesFeature.isEnabled && isAuthenticated }

    func loadTeamDetail() async throws -> AccountTeamDetail {
        Self.accountTeamDetail(try await cloudTeamDetail())
    }

    func inviteTeamMembers(emails: [String], role: AccountTeamRole) async throws -> AccountTeamInviteOutcome {
        let result = try await cloudInviteTeamMembers(emails: emails, role: Self.cloudRole(role))
        return AccountTeamInviteOutcome(
            sentEmails: result.invitations.compactMap(\.email),
            failedEmails: result.failed.map(\.email)
        )
    }

    func createTeamInviteLink() async throws -> AccountTeamInviteLinkOutcome {
        let created = try await cloudCreateTeamInviteLink(expiresInDays: 7, maxUses: nil)
        return AccountTeamInviteLinkOutcome(url: created.url, expiresAt: created.link.expiresAt)
    }

    func revokeTeamInvitation(id: String) async throws {
        try await cloudRevokeTeamInvitation(invitationID: id)
    }

    func revokeTeamInviteLink(id: String) async throws {
        try await cloudRevokeTeamInviteLink(linkID: id)
    }

    func removeTeamMember(userID: String) async throws {
        try await cloudRemoveTeamMember(userID: userID)
    }

    func changeTeamMemberRole(userID: String, role: AccountTeamRole) async throws {
        _ = try await cloudChangeTeamMemberRole(userID: userID, role: Self.cloudRole(role))
    }

    func teamManagementMessage(for error: Error) -> String {
        Self.teamMembersUserMessage(error)
    }

    private static func cloudRole(_ role: AccountTeamRole) -> CloudTeamRole {
        role == .admin ? .admin : .member
    }

    private static func accountRole(_ role: CloudTeamRole) -> AccountTeamRole {
        role == .admin ? .admin : .member
    }

    static func accountTeamDetail(_ detail: CloudTeamDetail) -> AccountTeamDetail {
        AccountTeamDetail(
            teamID: detail.team.id,
            teamName: detail.team.displayName,
            viewerUserID: detail.viewer.userId,
            viewerRole: accountRole(detail.viewer.role),
            canInvite: detail.canInvite,
            canRemoveMembers: detail.viewer.role == .admin && detail.viewer.permissions.removeMembers,
            members: detail.members.map { member in
                AccountTeamMember(
                    userID: member.userId,
                    displayName: member.displayName,
                    email: member.email,
                    role: accountRole(member.role),
                    isViewer: member.isViewer
                )
            },
            invitations: detail.invitations.map { invitation in
                AccountTeamInvitation(
                    id: invitation.id,
                    email: invitation.email,
                    role: accountRole(invitation.role),
                    expiresAt: invitation.expiresAt
                )
            },
            links: detail.links.map { link in
                AccountTeamInviteLink(id: link.id, expiresAt: link.expiresAt, maxUses: link.maxUses, useCount: link.useCount)
            },
            memberLimit: detail.billing.memberLimit
        )
    }
}
