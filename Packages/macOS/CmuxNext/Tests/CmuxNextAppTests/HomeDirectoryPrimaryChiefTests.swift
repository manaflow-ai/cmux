@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextHomeEngine
import Foundation
import Testing

/// The primary Chief (Lawrence 2026-11-02: "you just talk to primary chief, and you can designate
/// which one is primary chief"): texts to the cmux line go to the account's default Chief record.
/// Settings, `cmux chief primary` and the `/primary` text all set the same flag, `chief.update
/// {is_default: true}` at the record's revision; UserDO clears it on every other Chief.
@MainActor @Suite struct HomeDirectoryPrimaryChiefTests {
    @MainActor final class FakeAccount {
        var chiefs: [[String: Any]] = [
            ["id": "agent_ada", "display_name": "Chief", "is_default": true, "rev": 3, "main_conversation": "conv_ada", "archived_at": NSNull()],
            ["id": "agent_muse", "display_name": "Muse", "is_default": false, "rev": 5, "main_conversation": "conv_muse", "archived_at": NSNull()],
        ]
        var updates: [[String: Any]] = []
        var refuse: [String] = []

        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            let op = body["op"] as? String
            if op == "chief.list" { return ["ok": true, "value": ["chiefs": chiefs]] }
            guard op == "chief.update", let params = body["params"] as? [String: Any], let id = params["chief"] as? String else { return ["ok": true] }
            updates.append(params)
            if !refuse.isEmpty {
                let code = refuse.removeFirst()
                if code == "revision.conflict" { bump(id) }
                throw FeedServiceError.owner(code: code, message: code)
            }
            chiefs = chiefs.map { c in
                var c = c
                let mine = c["id"] as? String == id
                if mine || c["is_default"] as? Bool == true { c["rev"] = (c["rev"] as? Int ?? 0) + 1 }
                c["is_default"] = mine
                return c
            }
            return ["ok": true, "value": chiefs.first { $0["id"] as? String == id }!]
        }

        func bump(_ id: String) {
            chiefs = chiefs.map { c in
                var c = c
                if c["id"] as? String == id { c["rev"] = (c["rev"] as? Int ?? 0) + 1 }
                return c
            }
        }
    }

    static func directory(_ account: FakeAccount) -> HomeDirectory {
        HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
    }

    @Test func makingAChiefPrimarySetsItsDefaultFlagAndClearsTheOld() async {
        let account = FakeAccount()
        let directory = Self.directory(account)
        await directory.refreshChiefs()
        let failure = await directory.makePrimaryChief("agent_muse")
        #expect(failure == nil)
        #expect(account.updates.count == 1)
        #expect(account.updates.first?["chief"] as? String == "agent_muse")
        #expect(account.updates.first?["expected_rev"] as? Int == 5)
        #expect(account.updates.first?["is_default"] as? Bool == true)
        #expect(directory.chiefs.first { $0.id == "agent_muse" }?.isDefault == true)
        #expect(directory.chiefs.first { $0.id == "agent_ada" }?.isDefault == false)
    }

    @Test func theCurrentPrimarySendsNothing() async {
        let account = FakeAccount()
        let directory = Self.directory(account)
        await directory.refreshChiefs()
        #expect(await directory.makePrimaryChief("agent_ada") == nil)
        #expect(account.updates.isEmpty)
    }

    /// Another device changed the Chief since the list was read: one fresh read, then the update.
    @Test func aRevisionConflictReadsAgainOnce() async {
        let account = FakeAccount()
        account.refuse = ["revision.conflict"]
        let directory = Self.directory(account)
        await directory.refreshChiefs()
        #expect(await directory.makePrimaryChief("agent_muse") == nil)
        #expect(account.updates.map { $0["expected_rev"] as? Int } == [5, 6])
    }

    @Test func aNameFindsTheChiefAndAnUnknownOneIsNotFound() async {
        let account = FakeAccount()
        let directory = Self.directory(account)
        await directory.refreshChiefs()
        #expect(directory.chiefNamed("muse")?.id == "agent_muse")
        #expect(directory.chiefNamed("agent_ada")?.id == "agent_ada")
        #expect(await directory.makePrimaryChief("agent_nobody") == .notFound)
    }
}
