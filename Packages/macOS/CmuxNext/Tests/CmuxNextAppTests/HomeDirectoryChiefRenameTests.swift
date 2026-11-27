@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextHomeEngine
import Foundation
import Testing

/// A cloud Chief's name is its UserDO record's (`chief.update {display_name}`); the Mac's Chief
/// card sent the local daemon's set-title op instead, which never reaches a cloud conversation
/// (and the cloud refuses `title.set` on a Chief's conversation), so every rename of a cloud
/// Chief failed with "Try again in a moment". The directory renames the record now.
@MainActor @Suite struct HomeDirectoryChiefRenameTests {
    /// The account's API, answering `chief.list` from `chiefs` and each `chief.update` from `updates`.
    @MainActor final class FakeAccount {
        var rev = 3
        var name = "Chief"
        var updates: [[String: Any]] = []
        var refuse: [String] = []
        var signedOut = false

        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            if signedOut { throw FeedServiceError.signedOut }
            let op = body["op"] as? String
            if op == "chief.list" {
                return ["ok": true, "value": ["chiefs": [["id": "agent_ada", "display_name": name, "is_default": true, "rev": rev,
                                                         "main_conversation": "conv_ada", "archived_at": NSNull()]]]]
            }
            guard op == "chief.update", let params = body["params"] as? [String: Any] else { return ["ok": true] }
            updates.append(params)
            if !refuse.isEmpty {
                let code = refuse.removeFirst()
                if code == "revision.conflict" { rev += 1 }
                throw FeedServiceError.owner(code: code, message: code)
            }
            rev += 1
            name = params["display_name"] as? String ?? name
            return ["ok": true, "value": ["id": "agent_ada", "display_name": name, "is_default": true, "rev": rev,
                                          "main_conversation": "conv_ada", "archived_at": NSNull()]]
        }
    }

    static func directory(_ account: FakeAccount) -> HomeDirectory {
        HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
    }

    @Test func aCloudChiefRenameUpdatesItsRecord() async {
        let account = FakeAccount()
        let directory = Self.directory(account)
        await directory.refreshChiefs()
        let failure = await directory.renameChief(conversation: "conv_ada", to: "Ada")
        #expect(failure == nil)
        #expect(account.updates.count == 1)
        #expect(account.updates.first?["chief"] as? String == "agent_ada")
        #expect(account.updates.first?["expected_rev"] as? Int == 3)
        #expect(account.updates.first?["display_name"] as? String == "Ada")
        #expect(directory.chiefs.first?.name == "Ada")
    }

    /// Another device changed the Chief since the list was read: one fresh read, then the rename.
    @Test func aRevisionConflictReadsAgainOnce() async {
        let account = FakeAccount()
        account.refuse = ["revision.conflict"]
        let directory = Self.directory(account)
        await directory.refreshChiefs()
        let failure = await directory.renameChief(conversation: "conv_ada", to: "Ada")
        #expect(failure == nil)
        #expect(account.updates.map { $0["expected_rev"] as? Int } == [3, 4])
    }

    /// The card names the real reason, not "Try again in a moment".
    @Test func aFailureSaysWhy() async {
        let signedOut = FakeAccount()
        signedOut.signedOut = true
        #expect(await Self.directory(signedOut).renameChief(conversation: "conv_ada", to: "Ada") == .signedOut)

        let refused = FakeAccount()
        refused.refuse = ["validation.invalid"]
        let directory = Self.directory(refused)
        await directory.refreshChiefs()
        #expect(await directory.renameChief(conversation: "conv_ada", to: "Ada") == .invalidName)

        let unknown = Self.directory(FakeAccount())
        await unknown.refreshChiefs()
        #expect(await unknown.renameChief(conversation: "conv_other", to: "Ada") == .notFound)
    }
}
