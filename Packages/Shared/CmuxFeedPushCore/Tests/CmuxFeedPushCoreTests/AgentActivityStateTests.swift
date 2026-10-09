import Foundation
import Testing
@testable import CmuxFeedPushCore

@Suite struct AgentActivityStateTests {
    @Test func decodesTheOwnersContentState() throws {
        // The JSON FeedDO sends in aps.content-state (backend push/live-activity.ts).
        let json = #"{"phase":"needs_input","title":"Allow npm install?","started":1800000000,"item":"fi_7"}"#
        let state = try JSONDecoder().decode(AgentActivityState.self, from: Data(json.utf8))
        #expect(state.phase == .needsInput)
        #expect(state.item == "fi_7")
        #expect(state.startedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(state.detail == nil)
    }

    @Test func roundTrips() throws {
        let state = AgentActivityState(phase: .running, title: "Fix login", detail: "claude", started: Date(timeIntervalSince1970: 10))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AgentActivityState.self, from: data) == state)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["phase"] as? String == "running")
        #expect(object?["started"] as? Double == 10)
    }

    @Test func idsMatchTheOwnersPattern() {
        #expect(AgentActivityState.isActivityID(AgentActivityState.makeID()))
        #expect(!AgentActivityState.isActivityID("act_"))
        #expect(!AgentActivityState.isActivityID("act_a-b"))
        #expect(!AgentActivityState.isActivityID("task_1"))
    }

    @Test func registerOpCarriesTokenSubjectAndStart() throws {
        let op = CloudOp.registerActivity(id: "act_ab12", pushToken: Data([0x0a, 0xff]),
                                          subject: AgentActivitySubject(host: "h_mac", task: "task_1"),
                                          title: "Fix login", startedAt: Date(timeIntervalSince1970: 2), idempotencyKey: "k")
        let body = try JSONSerialization.jsonObject(with: op.body()) as? [String: Any]
        let params = body?["params"] as? [String: Any]
        #expect(body?["op"] as? String == "notify.activity.register")
        #expect(params?["push_token"] as? String == "0aff")
        #expect(params?["started_at"] as? Int == 2000)
        #expect((params?["subject"] as? [String: Any])?["task"] as? String == "task_1")
        #expect((params?["subject"] as? [String: Any])?["terminal"] == nil)
        let end = try JSONSerialization.jsonObject(with: CloudOp.endActivity(id: "act_ab12", idempotencyKey: "e").body()) as? [String: Any]
        #expect(end?["op"] as? String == "notify.activity.end")
    }

    @Test func preferencesOpListsEnabledKindsSorted() throws {
        var prefs = NotificationPreferences()
        prefs.set(.finished, enabled: false)
        prefs.timeSensitive = false
        let body = try JSONSerialization.jsonObject(with: CloudOp.setPushPreferences(prefs, idempotencyKey: "p").body()) as? [String: Any]
        let params = body?["params"] as? [String: Any]
        #expect(body?["op"] as? String == "push.prefs.set")
        #expect(params?["kinds"] as? [String] == ["permission", "planApproval", "question", "terminalAlert"])
        #expect(params?["time_sensitive"] as? Bool == false)
        #expect(params?["sound"] as? Bool == true)
    }

    @Test func jsonValueConvertsFoundation() {
        #expect(JSONValue(foundation: ["a": [1, "x", true]]) == .object(["a": .array([.int(1), .string("x"), .bool(true)])]))
        #expect(JSONValue(foundation: 1.5) == nil)
        #expect(JSONValue(foundation: Date()) == nil)
    }
}
