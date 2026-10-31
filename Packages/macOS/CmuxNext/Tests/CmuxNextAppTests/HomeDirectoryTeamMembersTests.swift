@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Testing

/// Home lists the people of the active team (a625, then one team at a time: the user, 2026-10-29).
/// A session acts in its personal team unless a request names another (`x-cmux-team`), so the
/// active team's `team.members.list` names it.
@MainActor @Suite struct HomeDirectoryTeamMembersTests {
    /// The account's API: `user.teams.list` from `teams`, `team.members.list` from `members` by the team named.
    @MainActor final class FakeAccount {
        let personal = "team_personal0000000000"
        var teams: [String] = ["team_manaflow000000000"]
        var members: [String: [(user: String, name: String)]] = [:]
        var refused: Set<String> = []
        var asked: [String?] = []

        func call(_ path: String, _ body: [String: Any], team: String?) async throws -> [String: Any] {
            switch body["op"] as? String {
            case "user.teams.list":
                let list = [personal] + teams
                return ["ok": true, "value": ["teams": list.map { ["id": $0, "kind": $0 == personal ? "personal" : "stack"] },
                                              "incomplete": false]]
            case "team.members.list":
                asked.append(team)
                let id = team ?? personal
                if refused.contains(id) { throw FeedServiceError.owner(code: "auth.forbidden", message: "the guest role may not read team.members.list") }
                let list = (members[id] ?? []).map { ["user": $0.user, "display_name": $0.name, "role": "member"] }
                return ["ok": true, "value": ["team": id, "members": list]]
            case "chief.list":
                return ["ok": true, "value": ["chiefs": [[String: Any]]()]]
            default:
                return ["ok": true]
            }
        }
    }

    static func directory(_ account: FakeAccount, active: String? = "team_manaflow000000000") -> HomeDirectory {
        HomeDirectory(call: { try await account.call($0, $1, team: nil) },
                      teamCall: { try await account.call($0, $1, team: $2) },
                      activeTeam: { active },
                      me: { "me" })
    }

    /// The user, 2026-10-29: "should only show for a team at a time… no multi team". Home lists the
    /// people of the active team (Switch Active Team), not of every team the user is in.
    @Test func listsOnlyTheActiveTeam() async {
        let account = FakeAccount()
        account.teams = ["team_manaflow000000000", "team_design0000000000"]
        account.members = [account.personal: [("me", "Me")],
                           "team_manaflow000000000": [("me", "Me"), ("ben", "Ben Ross"), ("ann", "Ann Lee")],
                           "team_design0000000000": [("ann", "Ann Lee"), ("cat", "Cat Diaz")]]
        let directory = Self.directory(account, active: "team_design0000000000")
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Ann Lee", "Cat Diaz"])
        #expect(account.asked == ["team_design0000000000"])
    }

    /// Each person once, even when the team lists them twice.
    @Test func listsEachMemberOnce() async {
        let account = FakeAccount()
        account.members = ["team_manaflow000000000": [("ben", "Ben Ross"), ("ben", "Ben Ross"), ("me", "Me")]]
        let directory = Self.directory(account)
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Ben Ross"])
    }

    /// With no active team (none loaded yet), only the personal team is read, never every team.
    @Test func noActiveTeamReadsOnlyThePersonalTeam() async {
        let account = FakeAccount()
        account.members = [account.personal: [("me", "Me"), ("pat", "Pat")], "team_manaflow000000000": [("ben", "Ben Ross")]]
        let directory = Self.directory(account, active: nil)
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Pat"])
        #expect(account.asked == [nil])
    }

    /// An active team whose role may not list members (a guest) lists nobody: never another team.
    @Test func aRefusedActiveTeamListsNobody() async {
        let account = FakeAccount()
        account.teams = ["team_manaflow000000000", "team_guest00000000000"]
        account.members = ["team_manaflow000000000": [("ben", "Ben Ross")], "team_guest00000000000": [("eve", "Eve")]]
        account.refused = ["team_guest00000000000"]
        let directory = Self.directory(account, active: "team_guest00000000000")
        await directory.refresh()
        #expect(directory.teamMembers.isEmpty, "a refused team lists nobody, never another team's people")
    }
}
