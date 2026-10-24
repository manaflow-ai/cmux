@testable import CmuxNextApp
import CmuxNextHome
import Foundation
import Testing

/// New Message lists the people of every team the user is in (a625). A session acts in its
/// personal team unless a request names another (`x-cmux-team`), so `team.members.list` with
/// no team listed only the personal team and a shared team's members never showed up.
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

    static func directory(_ account: FakeAccount) -> HomeDirectory {
        HomeDirectory(call: { try await account.call($0, $1, team: nil) },
                      teamCall: { try await account.call($0, $1, team: $2) },
                      me: { "me" })
    }

    @Test func listsTheMembersOfEveryTeamOnce() async {
        let account = FakeAccount()
        account.teams = ["team_manaflow000000000", "team_design0000000000"]
        account.members = [account.personal: [("me", "Me")],
                           "team_manaflow000000000": [("me", "Me"), ("ben", "Ben Ross"), ("ann", "Ann Lee")],
                           "team_design0000000000": [("ann", "Ann Lee"), ("cat", "Cat Diaz")]]
        let directory = Self.directory(account)
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Ann Lee", "Ben Ross", "Cat Diaz"])
        #expect(Set(account.asked.compactMap { $0 }) == ["team_manaflow000000000", "team_design0000000000"])
    }

    /// A team whose role may not list members (a guest) leaves out only that team.
    @Test func aTeamThatRefusesKeepsTheOthers() async {
        let account = FakeAccount()
        account.teams = ["team_manaflow000000000", "team_guest00000000000"]
        account.members = ["team_manaflow000000000": [("ben", "Ben Ross")], "team_guest00000000000": [("eve", "Eve")]]
        account.refused = ["team_guest00000000000"]
        let directory = Self.directory(account)
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Ben Ross"])
    }
}
