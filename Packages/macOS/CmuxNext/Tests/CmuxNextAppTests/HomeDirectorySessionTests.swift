@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Observation
import Testing

/// Lawrence 2026-10-28: "i want to be able to see everyone in my team by default". Home read the
/// team once, when its page opened at launch, while the stored sign-in was still being restored
/// (`isAuthenticated` is false until then): that read failed as signed out and nothing read the
/// team again, so the list and New Message's To: had no teammates until a New Message was opened.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HomeDirectorySessionTests {
    /// The signed-in session as Home sees it: nil while signed out or still restoring.
    @Observable @MainActor final class FakeSession {
        var key: String?
    }

    static func directory(_ account: HomeDirectoryTeamMembersTests.FakeAccount, session: FakeSession) -> HomeDirectory {
        HomeDirectory(call: { path, body in
                          guard session.key != nil else { throw FeedServiceError.signedOut }
                          return try await account.call(path, body, team: nil)
                      },
                      teamCall: { path, body, team in
                          guard session.key != nil else { throw FeedServiceError.signedOut }
                          return try await account.call(path, body, team: team)
                      },
                      activeTeam: { session.key?.split(separator: "|").dropFirst().first.map(String.init) },
                      me: { "me" })
    }

    static func manaflow() -> HomeDirectoryTeamMembersTests.FakeAccount {
        let account = HomeDirectoryTeamMembersTests.FakeAccount()
        account.members = [account.personal: [("me", "Me")],
                           "team_manaflow000000000": [("me", "Me"), ("austin", "Austin"), ("leo", "Leo"), ("aziz", "Aziz")]]
        return account
    }

    /// The first value of the directory's team that `done` accepts.
    static func team(of directory: HomeDirectory, until done: @escaping ([String]) -> Bool) async -> [String] {
        for await names in ObservationStream({ directory.teamMembers.map(\.name) }) where done(names) { return names }
        return []
    }

    /// Launch: Home starts before the stored session is restored; once it is, the team is listed.
    @Test func theTeamIsReadWhenTheRestoredSessionArrives() async {
        let account = Self.manaflow()
        let session = FakeSession()
        let directory = Self.directory(account, session: session)
        directory.follow { session.key }
        await Task.yield()
        session.key = "user_me|team_manaflow000000000"
        #expect(await Self.team(of: directory) { !$0.isEmpty } == ["Austin", "Aziz", "Leo"])
    }

    /// Switch Active Team: the other team's people replace the last team's, never added to them.
    @Test func switchingTheActiveTeamListsOnlyTheNewTeam() async {
        let account = Self.manaflow()
        account.teams.append("team_design0000000000")
        account.members["team_design0000000000"] = [("cat", "Cat Diaz"), ("leo", "Leo")]
        let session = FakeSession()
        session.key = "user_me|team_manaflow000000000"
        let directory = Self.directory(account, session: session)
        directory.follow { session.key }
        #expect(await Self.team(of: directory) { !$0.isEmpty } == ["Austin", "Aziz", "Leo"])
        session.key = "user_me|team_design0000000000"
        #expect(await Self.team(of: directory) { $0.contains("Cat Diaz") } == ["Cat Diaz", "Leo"])
    }

    /// Signing out drops the team, so another account never sees it.
    @Test func signingOutDropsTheTeam() async {
        let account = Self.manaflow()
        let session = FakeSession()
        session.key = "user_me|team_manaflow000000000"
        let directory = Self.directory(account, session: session)
        directory.follow { session.key }
        #expect(await Self.team(of: directory) { !$0.isEmpty }.count == 3)
        session.key = nil
        #expect(await Self.team(of: directory) { $0.isEmpty } == [])
    }

    /// The personal team's list failing (its owner busy) still lists the active team's members.
    @Test func aFailedPersonalTeamReadKeepsTheActiveTeam() async {
        let account = Self.manaflow()
        account.refused = [account.personal]
        let session = FakeSession()
        session.key = "user_me|team_manaflow000000000"
        let directory = Self.directory(account, session: session)
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Austin", "Aziz", "Leo"])
    }
}
