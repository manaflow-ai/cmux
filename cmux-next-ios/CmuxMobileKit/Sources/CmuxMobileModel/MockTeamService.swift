#if DEBUG
import Foundation

/// DEBUG mock mode's team API: the sample teams with an admin team
/// (Manaflow: rename and delete, pending invitations, a plan) and a member
/// team (Build Fleet: read only). `-cmux-mobile-mock-team-subscribed` makes
/// Manaflow refuse deletion for its subscription, as the server does.
public actor MockTeamService: TeamManaging {
    private var names: [String: String] = ["team-manaflow": "Manaflow", "team-fleet": "Build Fleet"]
    private let you: (id: String, name: String)
    private let subscribed: Bool

    public init(you: (id: String, name: String) = ("mock", "Aziz Albahar"),
                subscribed: Bool = CommandLine.arguments.contains("-cmux-mobile-mock-team-subscribed")) {
        self.you = you
        self.subscribed = subscribed
    }

    public func team(id: String) async throws -> TeamDetail {
        let me = TeamDetail.Member(id: you.id, name: you.name, email: "aziz@example.com", role: nil, isYou: true)
        guard let name = names[id] else {
            if id.hasPrefix("personal-") { return TeamDetail(id: id, name: "Personal", role: nil, permissions: .none, members: [me]) }
            throw TeamServiceError.server(status: 404, code: "team_not_found", message: "Team not found.")
        }
        if id == "team-fleet" {
            return TeamDetail(id: id, name: name, role: .member, permissions: .none, members: [
                TeamDetail.Member(id: you.id, name: you.name, email: "aziz@example.com", role: .member, isYou: true),
                TeamDetail.Member(id: "mock-4", name: "Lawrence Chen", email: "lawrence@example.com", role: .admin, isYou: false),
                TeamDetail.Member(id: "mock-5", name: "Build Bot", email: "bot@example.com", role: .member, isYou: false),
            ], billing: TeamDetail.Billing(planID: "team", seats: 10, memberCount: 3, hasActiveSubscription: true))
        }
        return TeamDetail(id: id, name: name, role: .admin, permissions: .all, members: [
            TeamDetail.Member(id: you.id, name: you.name, email: "aziz@example.com", role: .admin, isYou: true),
            TeamDetail.Member(id: "mock-2", name: "Lawrence Chen", email: "lawrence@example.com", role: .admin, isYou: false),
            TeamDetail.Member(id: "mock-3", name: "Austin Wang", email: "austin@example.com", role: .member, isYou: false),
        ], invitations: [
            TeamDetail.Invitation(id: "inv-1", email: "sam@example.com", role: .member, expiresAt: Date().addingTimeInterval(6 * 86400)),
        ], billing: TeamDetail.Billing(planID: subscribed ? "team" : "pro", memberLimit: subscribed ? nil : 5, memberCount: 3,
                                       hasActiveSubscription: subscribed))
    }

    public func renameTeam(id: String, to name: String) async throws -> String {
        guard names[id] != nil, id != "team-fleet" else { throw TeamServiceError.server(status: 403, code: "forbidden", message: "") }
        names[id] = name
        return name
    }

    public func deleteTeam(id: String) async throws {
        guard names[id] != nil, id != "team-fleet" else { throw TeamServiceError.server(status: 403, code: "forbidden", message: "") }
        if subscribed { throw TeamServiceError.server(status: 409, code: "team_has_active_subscription", message: "") }
        names[id] = nil
    }
}
#endif
