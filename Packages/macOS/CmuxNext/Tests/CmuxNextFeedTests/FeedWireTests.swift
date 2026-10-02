@testable import CmuxNextFeed
import Foundation
import Testing

/// The owner's JSON (items taken from backend/catalog/feed-vectors.json) decodes
/// into the client model, and intents encode into the owner's op params.
@MainActor
struct FeedWireTests {
    private static let answeredApprove = #"""
{"actions": [], "answer": {"at": 1004000, "by": "inst_ios00000000000000000", "device": "iPhone", "value": {"decision": "allow", "scope": "session"}}, "archived_at": null, "attachments": [], "body": "", "cancel": null, "closed_at": 1004000, "context": {}, "count": 1, "created_at": 1000000, "dedupe_key": "claude-code:s1:h1", "expires_at": 87400000, "home": "cloud", "id": "fi_1d4b39ea0103e14a0edd", "kind": "approve", "needs_mac": false, "open": null, "order": 1, "poster": {"agent": "agent_a", "install": "inst_dmn00000000000000000", "kind": "agent", "label": "", "scope": "inst:inst_dmn00000000000000000/agent:agent_a"}, "priority": "high", "prompt": {"action": {"command": "npm run build", "cwd": "/repo", "summary": "Run the build", "type": "command"}, "scopes": ["once", "session"]}, "push_due_at": null, "pushed_at": null, "read_at": 1004000, "revision": 2, "seen_at": null, "snoozed_until": null, "state": "answered", "thread": null, "title": "approve", "type": "request", "updated_at": 1004000}
"""#
    private static let choice = #"""
{"actions": [], "answer": null, "archived_at": null, "attachments": [], "body": "", "cancel": null, "closed_at": null, "context": {}, "count": 1, "created_at": 1000000, "dedupe_key": null, "expires_at": 87400000, "home": "cloud", "id": "fi_fe263bfcb95a5d23aa81", "kind": "choice", "needs_mac": false, "open": null, "order": 1, "poster": {"agent": "agent_a", "install": "inst_dmn00000000000000000", "kind": "agent", "label": "", "scope": "inst:inst_dmn00000000000000000/agent:agent_a"}, "priority": "high", "prompt": {"questions": [{"allow_other": true, "id": "db", "multi": false, "options": [{"id": "pg", "label": "Postgres"}, {"id": "sqlite", "label": "SQLite"}], "question": "Which database?"}, {"allow_other": false, "id": "feat", "multi": true, "options": [{"id": "auth", "label": "Auth"}, {"id": "push", "label": "Push"}, {"id": "sync", "label": "Sync"}], "question": "Which features?"}]}, "push_due_at": 1020000, "pushed_at": null, "read_at": null, "revision": 1, "seen_at": null, "snoozed_until": null, "state": "open", "thread": null, "title": "choice", "type": "request", "updated_at": 1000000}
"""#

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func decodesAnAnsweredApprove() throws {
        let item = try #require(FeedWireDecode.item(object(Self.answeredApprove)))
        #expect(item.kind == "approve")
        #expect(item.state == .answered)
        #expect(item.poster.kind == .agent)
        #expect(item.answer?.value == .approve(.init(.allow, scope: .session)))
        #expect(item.answer?.device == "iPhone")
        guard case let .approve(prompt) = item.prompt else { Issue.record("not approve"); return }
        #expect(prompt.action.command == "npm run build")
        #expect(prompt.scopes == [.once, .session])
        #expect(item.createdAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func decodesAChoicePrompt() throws {
        let item = try #require(FeedWireDecode.item(object(Self.choice)))
        guard case let .choice(prompt) = item.prompt else { Issue.record("not choice"); return }
        #expect(prompt.questions.map(\.id) == ["db", "feat"])
        #expect(prompt.questions[1].multi)
        #expect(item.isOpenRequest)
    }

    @Test func encodesIntentsAsOwnerOps() throws {
        let answer = FeedIntent(key: "k1", kind: .answer(item: "fi_1", value: .approve(.init(.deny, scope: .session))), at: Date())
        let (op, params) = try #require(FeedWireEncode.op(answer, unreadBefore: { _ in [] }))
        #expect(op == "feed.answer")
        // A denial carries no scope (the owner refuses one).
        #expect((params["answer"] as? [String: Any])?["scope"] == nil)
        #expect((params["answer"] as? [String: Any])?["decision"] as? String == "deny")
        let decline = try #require(FeedWireEncode.op(FeedIntent(key: "k2", kind: .decline(item: "fi_1"), at: Date()), unreadBefore: { _ in [] }))
        #expect(decline.op == "feed.cancel")
        #expect(decline.params["reason"] as? String == "declined")
        let all = try #require(FeedWireEncode.op(FeedIntent(key: "k3", kind: .markAllRead(before: Date()), at: Date()), unreadBefore: { _ in ["fi_a", "fi_b"] }))
        #expect(all.params["all"] as? Bool == true)
        #expect(FeedWireEncode.op(FeedIntent(key: "k4", kind: .markAllRead(before: Date()), at: Date()), unreadBefore: { _ in [] }) == nil)
    }

    @Test func decodesFramesAndAClosedReject() throws {
        let reject = #"{"t":"reject","idempotency_key":"k9","code":"feed.closed","message":"closed","details":{"item":"# + Self.answeredApprove + "}}"
        guard case let .reject(key, value) = FeedWireFrame.decode(Data(reject.utf8)) else { Issue.record("not a reject"); return }
        #expect(key == "k9")
        #expect(value.closedItem?.state == .answered)
        let event = #"{"t":"event","seq":7,"items":["# + Self.choice + #"],"present":["fi_x"]}"#
        guard case let .event(seq, items, present) = FeedWireFrame.decode(Data(event.utf8)) else { Issue.record("not an event"); return }
        #expect(seq == 7)
        #expect(items.count == 1)
        #expect(present == ["fi_x"])
    }
}
