#if os(iOS)
import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// The Mac Chief with the Mac offline (a450, logs/iphone-chief-DESIGN.md):
/// the phone finds its Mac in the team directory, reads the Mac's cloud copy,
/// tells a queued message from a delivered or refused one, and hands a
/// message to the Cloud Chief with the recent messages.
@Suite struct ChiefReplicaTests {
    let wire = ChiefWire(identity: .standard)

    /// The account's own Mac by name; its only Mac when no name matches; never another person's.
    @Test func picksTheAccountsMac() {
        let hosts: [[String: Any]] = [
            ["id": "host_a", "name": "Studio", "platform": "macos", "owner_user": "user_me"],
            ["id": "host_b", "name": "Laptop", "platform": "macos", "owner_user": "user_me"],
            ["id": "host_c", "name": "Laptop", "platform": "macos", "owner_user": "user_other"],
            ["id": "host_d", "name": "Box", "platform": "linux", "owner_user": "user_me"],
        ]
        #expect(ChiefSources.pickHost(hosts, userID: "user_me", macName: "laptop") == "host_b")
        #expect(ChiefSources.pickHost(hosts, userID: "user_me", macName: "Gone") == nil)
        #expect(ChiefSources.pickHost(Array(hosts.prefix(1)), userID: "user_me", macName: nil) == "host_a")
        #expect(ChiefSources.pickHost(hosts, userID: "user_nobody", macName: "Laptop") == nil)
    }

    /// The copy the Mac publishes (`{conversation, messages}`) reads as the conversation and its messages.
    @Test func decodesTheMacsCopy() throws {
        let state: [String: Any] = [
            "conversation": [
                "id": "conv_1", "title": "Chief", "created_at": "2026-10-21T00:00:00Z",
                "participants": [
                    ["id": "user_local", "kind": "human", "display_name": "You"],
                    ["id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"],
                ],
                "read_cursors": ["agent_mux": 2],
            ],
            "messages": [
                ["id": "m1", "conversation": "conv_1", "seq": 1, "client_msg_id": "c1", "author": "user_local",
                 "parts": [["type": "text", "text": "hi"]], "created_at": "2026-10-21T00:00:01Z"],
                ["id": "m2", "conversation": "conv_1", "seq": 2, "client_msg_id": "cloud-c2", "author": "agent_mux",
                 "parts": [["type": "text", "text": "hello"]], "created_at": "2026-10-21T00:00:02Z"],
            ],
        ]
        let copy = try #require(ChiefReplicaBackend.Copy.decode(state, wire: wire))
        #expect(copy.info.id == "conv_1")
        #expect(copy.messages.map(\.text) == ["hi", "hello"])
        #expect(copy.messages.first?.senderID == "user_local")
        // A message the phone sent through the cloud names its pending row by the bare key.
        #expect(copy.messages.map(\.clientMessageID) == ["c1", "c2"])
        #expect(ChiefReplicaBackend.Copy.decode(["messages": []], wire: wire) == nil)
    }

    /// `op.queued` means the Mac is offline and the cloud keeps it; a settle means delivered;
    /// a refusal says why; frames of other keys decide nothing.
    @Test func readsTheSendOutcome() {
        typealias Outcome = ChiefReplicaBackend.Outcome
        #expect(Outcome.of(["t": "op.queued", "idempotency_key": "k", "position": 2], key: "k") == .queued(position: 2))
        #expect(Outcome.of(["t": "request-settled", "idempotency_key": "k", "ok": true], key: "k") == .delivered)
        #expect(Outcome.of(["t": "reject", "idempotency_key": "k", "code": "mailbox_full", "message": "full"], key: "k") == .refused("full"))
        #expect(Outcome.of(["t": "request-settled", "idempotency_key": "k", "ok": false], key: "k") == nil)
        #expect(Outcome.of(["t": "op.queued", "idempotency_key": "other"], key: "k") == nil)
    }

    /// The hand-off carries the request first, then the context, oldest first, one line each.
    @Test func handOffQuotesTheRecentMessages() {
        let now = Date()
        let context = [
            ConversationMessage(id: "1", seq: 1, clientMessageID: nil, senderID: "user_local", sentAt: now, text: "build it"),
            ConversationMessage(id: "2", seq: 2, clientMessageID: nil, senderID: "agent_mux", sentAt: now, text: "on it\nnow"),
        ]
        let text = ChiefSources.handOffText("is it done?", context: context, meID: "user_local")
        #expect(text.hasPrefix("My Mac is offline"))
        #expect(text.contains("is it done?\n\nRecent messages"))
        #expect(text.hasSuffix("Me: build it\nMac Chief: on it now"))
        #expect(!ChiefSources.handOffText("hi", context: [], meID: "user_local").contains("Recent messages"))
    }
}
#endif
