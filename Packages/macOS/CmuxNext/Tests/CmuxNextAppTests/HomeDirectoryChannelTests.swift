@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextHomeEngine
import Foundation
import Testing

/// Chief channels (plans/cmux-next/chief-channels-DESIGN.md): New Channel, `cmux chat channel create` and MCP
/// make a channel with `channel.create`, then invite each person on the channel: an email gets an invite
/// (`invite.create`), an account is added (`participants.add`), so a refusal names that person only.
@MainActor @Suite struct HomeDirectoryChannelTests {
    @MainActor final class FakeAccount {
        var ops: [(op: String, params: [String: Any])] = []
        var refuseInvite: String?

        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            let op = body["op"] as? String ?? ""
            let params = body["params"] as? [String: Any] ?? [:]
            ops.append((op, params))
            switch op {
            case "channel.create":
                return ["ok": true, "value": ["id": "agent_launch", "display_name": params["display_name"] as? String ?? "Launch Chief",
                                              "is_default": false, "rev": 1, "main_conversation": "conv_launch", "archived_at": NSNull(),
                                              "channel": ["conversation": "conv_launch", "title": params["title"] as? String ?? ""]]]
            case "invite.create" where refuseInvite != nil:
                throw FeedServiceError.owner(code: refuseInvite!, message: refuseInvite!)
            default:
                return ["ok": true, "value": [:] as [String: Any]]
            }
        }
    }

    @Test func aChannelIsCreatedThenEachPersonInvited() async throws {
        let account = FakeAccount()
        let directory = HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
        let made = try await directory.createChannel(title: " Launch ", chiefName: nil,
                                                     people: [.email("ana@example.com"), .account("user_aaaaaaaaaaaaaaaaaaaa")])
        #expect(made.chief.id == "agent_launch")
        #expect(made.conversation == "conv_launch")
        #expect(made.invited.map(\.ok) == [true, true])
        #expect(account.ops.map(\.op) == ["channel.create", "invite.create", "participants.add"])
        #expect(account.ops[0].params["title"] as? String == "Launch")
        #expect(account.ops[0].params["display_name"] == nil)
        #expect(account.ops[1].params["conversation"] as? String == "conv_launch")
        #expect((account.ops[1].params["address"] as? [String: String])?["email"] == "ana@example.com")
        #expect((account.ops[2].params["participant"] as? [String: String])?["id"] == "user_aaaaaaaaaaaaaaaaaaaa")
        #expect(directory.chiefs.contains { $0.id == "agent_launch" })
    }

    @Test func aRefusedInviteNamesThatPersonAndKeepsTheChannel() async throws {
        let account = FakeAccount()
        account.refuseInvite = "invite_limit"
        let directory = HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
        let made = try await directory.createChannel(title: "Launch", chiefName: "Scout", people: [.email("ana@example.com")])
        #expect(made.invited.count == 1)
        #expect(made.invited.first?.ok == false)
        #expect(made.invited.first?.code == "invite_limit")
        #expect(account.ops[0].params["display_name"] as? String == "Scout")
    }

    @Test func anEmptyTitleIsRefusedBeforeAnyCall() async {
        let account = FakeAccount()
        let directory = HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
        await #expect(throws: FeedServiceError.self) { _ = try await directory.createChannel(title: "  ", chiefName: nil, people: []) }
        #expect(account.ops.isEmpty)
    }
}
