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

    /// Pending invitations addressed to the person's verified emails (Settings > Accounts).
    public func receivedTeamInvitations() async throws -> [CMUXReceivedTeamInvitation] {
        try await Self.teamErrors { try await coordinator.receivedTeamInvitations() }
    }

    /// Joins the team an invitation names; the joined team becomes the active team, so the
    /// team's Cloud machines are the ones cmux lists next.
    @discardableResult
    public func acceptTeamInvitation(id: String) async throws -> CMUXTeamJoin {
        try await Self.teamErrors { try await coordinator.acceptTeamInvitation(id: id) }
    }

    /// Declines an invitation addressed to the person.
    public func declineTeamInvitation(id: String) async throws {
        try await Self.teamErrors { try await coordinator.declineTeamInvitation(id: id) }
    }

    /// Invites one address as a member and says how it went (Home's Invite to Team).
    ///
    /// - Parameters:
    ///   - email: The address, already validated.
    ///   - teamID: The team.
    /// - Returns: The answer; never throws.
    public func inviteOne(_ email: String, toTeam teamID: String) async -> CloudTeamInviteAnswer {
        let outcome: (code: String?, alreadyMember: Bool?)
        do {
            let result = try await inviteToTeam(id: teamID, emails: [email])
            outcome = (nil, result.failed.first.map(\.isAlreadyMember))
        } catch CMUXTeamError.forbidden {
            outcome = ("forbidden", nil)
        } catch {
            outcome = ("unavailable", nil)
        }
        struct Request: Encodable { var error: String?, firstFailureAlreadyMember: Bool? }
        struct Reply: Decodable { var answer: CloudTeamInviteAnswer }
        // Rust's `invite_answer`; an FFI that does not answer says cmux.com could not be reached.
        return CloudStartCore().call("cloud_auth_invite_answer", Request(error: outcome.code, firstFailureAlreadyMember: outcome.alreadyMember),
                                     as: Reply.self)?.answer ?? .unreachable
    }

    /// What the team's plan says about one more member (Rust's `seat_facts`); nil when the detail cannot be read.
    public func seatFacts(teamID: String) async -> CloudTeamSeatFacts? {
        guard let detail = try? await teamDetail(id: teamID) else { return nil }
        struct Request: Encodable {
            var inviteMembers: Bool, role: String?, planId: String?, hasActiveSubscription: Bool?
            var memberCount: Int?, memberLimit: Int?, members: Int
        }
        let billing = detail.billing
        let request = Request(inviteMembers: detail.viewer.permissions.inviteMembers, role: detail.viewer.role?.rawValue,
                              planId: billing?.planId, hasActiveSubscription: billing?.hasActiveSubscription,
                              memberCount: billing?.memberCount, memberLimit: billing?.memberLimit, members: detail.members.count)
        return CloudStartCore().call("cloud_auth_seat_facts", request, as: CloudTeamSeatFacts.self)
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

extension CloudAuth {
    /// A Cloud plan refusal's `details` for the agent pane: the active team, every team the person may
    /// switch to (the team menu's rows, the personal one first: cmux#39950) and whether they may switch,
    /// so the card names the team and offers their own (webviews cloudPlanTeams.ts). Data only, no rule here.
    public var planRefusalTeams: [String: Any] {
        var details: [String: Any] = ["teams": activeTeam.teams.map { ["id": $0.id, "name": $0.displayName] },
                                      "canSwitch": activeTeam.canSwitch]
        if let id = activeTeam.id { details["team"] = id }
        return details
    }
}
