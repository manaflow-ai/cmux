import CmuxAuthRuntime
import CmuxCloud
import CmuxControlSocket
import Foundation
import OSLog

private let authTeamLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth-team")

extension TerminalController {
    /// Every `auth.team.*` socket method. Mutations and roster reads run on
    /// the async worker path because they await the MainActor account flow.
    static let authTeamSocketMethods: Set<String> = [
        "auth.team.list", "auth.team.use", "auth.team.create",
        "auth.team.members", "auth.team.invite", "auth.team.invite_link",
        "auth.team.revoke_invite", "auth.team.remove_member", "auth.team.open_members",
    ]

    /// Handles the shared team-selection socket actions used by the CLI.
    /// Keeping the mutation here means CLI and SwiftUI both call the same
    /// coordinator operation and receive the same rollback semantics.
    nonisolated func v2AuthTeamResponse(_ request: V2SocketRequest) -> String {
        switch request.method {
        case "auth.team.list":
            return v2Ok(id: request.id, result: v2AuthTeamStatusPayload())
        case "auth.team.use":
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: String(localized: "socket.authTeam.asyncRequired", defaultValue: "Team actions require asynchronous socket dispatch.")
            )
        case _ where Self.authTeamSocketMethods.contains(request.method):
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: String(localized: "socket.authTeam.asyncRequired", defaultValue: "Team actions require asynchronous socket dispatch.")
            )
        default:
            return v2Error(
                id: request.id,
                code: "method_not_found",
                message: String(localized: "socket.authTeam.unknownMethod", defaultValue: "Unknown team action.")
            )
        }
    }

    private nonisolated func v2AuthTeamStatusPayload() -> [String: Any] {
        v2MainSync { self.v2AuthTeamStatusPayloadOnMain() }
    }

    /// Async socket path for team mutations. Socket connections must suspend
    /// while the MainActor-owned auth coordinator performs network work; they
    /// must not park a worker thread behind a semaphore.
    nonisolated func v2AuthTeamResponseAsync(_ request: ControlRequest) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        let id = request.id?.foundationObject
        switch request.method {
        case "auth.team.list":
            return v2Ok(id: id, result: await v2AuthTeamStatusPayloadAsync())
        case "auth.team.use":
            guard let teamID = params["team_id"] as? String,
                  !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingTeam", defaultValue: "A team id is required.")
                )
            }
            return await v2AuthTeamMutationAsync(id: id) { flow in
                try await flow.selectTeam(id: teamID)
            }
        case "auth.team.create":
            guard let displayName = params["display_name"] as? String,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingName", defaultValue: "A team name is required.")
                )
            }
            return await v2AuthTeamMutationAsync(id: id) { flow in
                _ = try await flow.createTeam(displayName: displayName)
            }
        case "auth.team.members":
            return await v2AuthTeamRosterAsync(id: id, teamID: params["team_id"] as? String) { flow, teamID in
                let detail: TeamRosterSocketPayload = try await flow.loadTeamDetail(teamID: teamID)
                return detail
            }
        case "auth.team.invite":
            let emails = (params["emails"] as? [String]) ?? (params["email"] as? String).map { [$0] } ?? []
            guard !emails.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "teamMembers.error.invalidEmail", defaultValue: "Enter at least one email address.")
                )
            }
            let role = CloudTeamRole(rawValue: (params["role"] as? String ?? "member").lowercased()) ?? .member
            return await v2AuthTeamRosterAsync(id: id, teamID: params["team_id"] as? String) { flow, teamID in
                let result = try await flow.inviteTeamMembers(teamID: teamID, emails: emails, role: role)
                let detail = try await flow.loadTeamDetail(teamID: teamID)
                return TeamRosterSocketResult(invite: result, detail: detail)
            }
        case "auth.team.invite_link":
            let expires = params["expires_in_days"] as? Int
            let maxUses = params["max_uses"] as? Int
            return await v2AuthTeamRosterAsync(id: id, teamID: params["team_id"] as? String) { flow, teamID in
                let created = try await flow.createTeamInviteLink(teamID: teamID, expiresInDays: expires, maxUses: maxUses)
                let detail = try await flow.loadTeamDetail(teamID: teamID)
                return TeamRosterSocketResult(link: created, detail: detail)
            }
        case "auth.team.revoke_invite":
            let invitationID = (params["invitation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let linkID = (params["link_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !invitationID.isEmpty || !linkID.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingInvitation", defaultValue: "An invitation id or link id is required.")
                )
            }
            return await v2AuthTeamRosterAsync(id: id, teamID: params["team_id"] as? String) { flow, teamID in
                if !invitationID.isEmpty {
                    try await flow.revokeTeamInvitation(teamID: teamID, invitationID: invitationID)
                } else {
                    try await flow.revokeTeamInviteLink(teamID: teamID, linkID: linkID)
                }
                let detail: TeamRosterSocketPayload = try await flow.loadTeamDetail(teamID: teamID)
                return detail
            }
        case "auth.team.remove_member":
            guard let userID = (params["user_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userID.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingUser", defaultValue: "A user id is required.")
                )
            }
            return await v2AuthTeamRosterAsync(id: id, teamID: params["team_id"] as? String) { flow, teamID in
                try await flow.removeTeamMember(teamID: teamID, userID: userID)
                // Leaving drops the caller's access, so a failed re-read is not an error.
                let detail: TeamRosterSocketPayload? = try? await flow.loadTeamDetail(teamID: teamID)
                return detail
            }
        case "auth.team.open_members":
            let focusInvite = params["focus_invite"] as? Bool ?? false
            return await v2AuthTeamMutationAsync(id: id) { flow in
                guard flow.confirmedTeamID != nil else { throw TeamMembersFlowError.noTeam }
                flow.showTeamMembers(focusInvite: focusInvite)
            }
        default:
            return v2Error(
                id: id,
                code: "method_not_found",
                message: String(localized: "socket.authTeam.unknownMethod", defaultValue: "Unknown team action.")
            )
        }
    }

    private nonisolated func v2AuthTeamMutationAsync(
        id: Any?,
        action: @escaping @MainActor (HostAccountFlow) async throws -> Void
    ) async -> String {
        guard let flow = await v2MainAsync({ self.accountFlow }) else {
            return v2Error(
                id: id,
                code: "auth_required",
                message: String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
            )
        }
        do {
            try await action(flow)
            return v2Ok(id: id, result: await v2AuthTeamStatusPayloadAsync())
        } catch {
            authTeamLog.error("team mutation failed: \(String(describing: error), privacy: .private)")
            return v2Error(
                id: id,
                code: "team_selection_failed",
                message: v2AuthTeamUserMessage(error)
            )
        }
    }

    /// Roster reads and invite mutations. The closure resolves the explicit
    /// `team_id` (or the confirmed active team) and returns the payload to
    /// serialize; API refusals keep their server error code.
    private nonisolated func v2AuthTeamRosterAsync(
        id: Any?,
        teamID: String?,
        action: @escaping @MainActor (HostAccountFlow, String?) async throws -> TeamRosterSocketPayload?
    ) async -> String {
        guard let flow = await v2MainAsync({ self.accountFlow }) else {
            return v2Error(
                id: id,
                code: "auth_required",
                message: String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
            )
        }
        do {
            let payload = try await action(flow, teamID)
            return v2Ok(id: id, result: payload?.socketDictionary ?? ["ok": true])
        } catch {
            authTeamLog.error("team roster action failed: \(String(describing: error), privacy: .private)")
            return v2Error(
                id: id,
                code: (error as? TeamsClientError)?.apiCode ?? "team_action_failed",
                message: v2AuthTeamUserMessage(error)
            )
        }
    }

    private nonisolated func v2AuthTeamUserMessage(_ error: Error) -> String {
        switch error {
        case AuthError.unauthorized:
            return String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
        case AuthClientError.teamNotAvailable:
            return String(localized: "socket.authTeam.notMember", defaultValue: "You are not a member of that team.")
        case AuthClientError.invalidTeamName:
            return String(localized: "socket.authTeam.invalidName", defaultValue: "Enter a team name.")
        case is TeamsClientError, is TeamMembersFlowError:
            return HostAccountFlow.teamMembersUserMessage(error)
        default:
            return String(localized: "socket.authTeam.failed", defaultValue: "Could not update the team. Try again.")
        }
    }

    private nonisolated func v2AuthTeamStatusPayloadAsync() async -> [String: Any] {
        await v2MainAsync {
            self.v2AuthTeamStatusPayloadOnMain()
        }
    }

    @MainActor
    private func v2AuthTeamStatusPayloadOnMain() -> [String: Any] {
        guard let coordinator = authCoordinator else {
            return ["signed_in": false, "teams": []]
        }
        var status: [String: Any] = ["signed_in": coordinator.isAuthenticated]
        if let teamID = coordinator.resolvedTeamID {
            status["selected_team_id"] = teamID
        }
        status["teams"] = coordinator.availableTeams.map { team in
            var value: [String: Any] = [
                "id": team.id,
                "display_name": team.displayName
            ]
            if let slug = team.slug { value["slug"] = slug }
            return value
        }
        return status
    }
}

/// Anything the roster socket methods return, flattened to snake_case JSON.
protocol TeamRosterSocketPayload: Sendable {
    var socketDictionary: [String: Any] { get }
}

extension CloudTeamDetail: TeamRosterSocketPayload {
    var socketDictionary: [String: Any] {
        var billing: [String: Any] = [
            "member_count": self.billing.memberCount,
            "has_active_subscription": self.billing.hasActiveSubscription,
        ]
        if let planId = self.billing.planId { billing["plan_id"] = planId }
        if let seats = self.billing.seats { billing["seats"] = seats }
        if let limit = self.billing.memberLimit { billing["member_limit"] = limit }
        return [
            "team": ["id": team.id, "display_name": team.displayName],
            "viewer": ["user_id": viewer.userId, "role": viewer.role.rawValue, "can_invite": canInvite],
            "members": members.map { member in
                var value: [String: Any] = ["user_id": member.userId, "role": member.role.rawValue, "is_viewer": member.isViewer]
                if let name = member.displayName { value["display_name"] = name }
                if let email = member.email { value["email"] = email }
                return value
            },
            "invitations": invitations.map(Self.socketInvitation),
            "links": links.map(Self.socketLink),
            "billing": billing,
        ]
    }

    static func socketInvitation(_ invitation: CloudTeamInvitation) -> [String: Any] {
        var value: [String: Any] = [
            "id": invitation.id,
            "role": invitation.role.rawValue,
            "expires_at": ISO8601DateFormatter().string(from: invitation.expiresAt),
        ]
        if let email = invitation.email { value["email"] = email }
        return value
    }

    static func socketLink(_ link: CloudTeamInviteLink) -> [String: Any] {
        var value: [String: Any] = [
            "id": link.id,
            "role": link.role.rawValue,
            "created_at": ISO8601DateFormatter().string(from: link.createdAt),
            "use_count": link.useCount,
        ]
        if let expiresAt = link.expiresAt { value["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
        if let maxUses = link.maxUses { value["max_uses"] = maxUses }
        return value
    }
}

/// A mutation result plus the refreshed roster.
struct TeamRosterSocketResult: TeamRosterSocketPayload {
    var invite: CloudTeamInviteResult?
    var link: CloudTeamInviteLinkCreated?
    var detail: CloudTeamDetail

    init(invite: CloudTeamInviteResult? = nil, link: CloudTeamInviteLinkCreated? = nil, detail: CloudTeamDetail) {
        self.invite = invite
        self.link = link
        self.detail = detail
    }

    var socketDictionary: [String: Any] {
        var value = detail.socketDictionary
        if let invite {
            value["sent"] = invite.invitations.map(CloudTeamDetail.socketInvitation)
            value["failed"] = invite.failed.map { ["email": $0.email, "code": $0.code] }
        }
        if let link {
            value["invite_link"] = ["url": link.url, "id": link.link.id]
        }
        return value
    }
}
