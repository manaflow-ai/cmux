import CmuxNextCloud
import Foundation
import Testing

/// `cloud.automation` (``CloudAutomationRelay``): which ops the app forwards to cmux Cloud for
/// `cmux automation --target cloud`, where each goes, that a mutation needs an idempotency key, and
/// that a refusal keeps its details (a plan refusal's checkout link).
@Suite struct CloudAutomationRelayTests {
    /// One posted request: the path and the body's string fields.
    struct Call: Sendable {
        let path: String
        let fields: [String: String]
    }

    actor Recorder {
        var calls: [Call] = []
        func add(_ path: String, _ body: Data) {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            calls.append(Call(path: path, fields: object.compactMapValues { $0 as? String }))
        }
        var count: Int { calls.count }
        var first: Call? { calls.first }
    }

    static func relay(_ recorder: Recorder, reply: String, status: Int = 200) -> CloudAutomationRelay {
        CloudAutomationRelay { path, body in
            await recorder.add(path, body)
            return (Data(reply.utf8), status)
        }
    }

    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test func readsGoToV1ReadWithoutAKey() async {
        let recorder = Recorder()
        let answer = Self.object(await Self.relay(recorder, reply: #"{"ok":true,"value":{"automations":[]}}"#)
            .forward(Self.data(["op": "automation.list", "params": ["limit": 50]])))
        #expect(answer["ok"] as? Bool == true)
        #expect((answer["value"] as? [String: Any])?["automations"] as? [Any] != nil)
        #expect(await recorder.count == 1)
        let first = await recorder.first
        #expect(first?.path == "v1/read")
        #expect(first?.fields["op"] == "automation.list")
        #expect(first?.fields["idempotency_key"] == nil)
    }

    @Test func mutationsGoToV1OpsWithTheCallersKey() async {
        let recorder = Recorder()
        _ = await Self.relay(recorder, reply: #"{"ok":true,"value":{"id":"run_x"}}"#)
            .forward(Self.data(["op": "automation.run", "params": ["automation": "auto_x"], "idempotency_key": "k-1"]))
        let first = await recorder.first
        #expect(first?.path == "v1/ops")
        #expect(first?.fields["idempotency_key"] == "k-1")
        #expect(first?.fields["origin"] == "cli")
    }

    @Test(arguments: ["automation.create", "automation.update", "automation.delete", "automation.run"])
    func aMutationWithoutAKeyIsRefusedBeforeAnyCall(op: String) async {
        let recorder = Recorder()
        let answer = Self.object(await Self.relay(recorder, reply: "{}").forward(Self.data(["op": op, "params": [String: Any]()])))
        #expect(answer["ok"] as? Bool == false)
        #expect((answer["error"] as? [String: Any])?["code"] as? String == "invalid_params")
        #expect(await recorder.count == 0)
    }

    @Test(arguments: ["feed.post", "team.members.remove", "automation.deploy", "automation.settings.set", ""])
    func otherOpsAreNotForwarded(op: String) async {
        let recorder = Recorder()
        let answer = Self.object(await Self.relay(recorder, reply: "{}").forward(Self.data(["op": op, "params": [String: Any](), "idempotency_key": "k"])))
        #expect(answer["ok"] as? Bool == false)
        #expect(await recorder.count == 0)
    }

    @Test func aRefusalKeepsItsDetails() async {
        let recorder = Recorder()
        let reply = #"{"ok":false,"error":{"code":"automation.plan.required","message":"the free plan has 1 Cloud job","details":{"plan":"pro","checkout":"https://api.test/v1/billing/plan/x.y"}}}"#
        let answer = Self.object(await Self.relay(recorder, reply: reply)
            .forward(Self.data(["op": "automation.create", "params": ["name": "Brief"], "idempotency_key": "k"])))
        let error = answer["error"] as? [String: Any]
        #expect(answer["ok"] as? Bool == false)
        #expect(error?["code"] as? String == "automation.plan.required")
        #expect((error?["details"] as? [String: Any])?["checkout"] as? String == "https://api.test/v1/billing/plan/x.y")
    }

    @Test func aFailedCallIsAnUnreachableOwnerNotACrash() async {
        let relay = CloudAutomationRelay { _, _ in throw URLError(.notConnectedToInternet) }
        let answer = Self.object(await relay.forward(Self.data(["op": "automation.list"])))
        #expect((answer["error"] as? [String: Any])?["code"] as? String == "owner.unreachable")
    }

    @Test(arguments: [(401, #"{"error":"Unauthorized"}"#), (500, "{}"), (200, #"{"ok":false}"#), (502, "<html>bad gateway</html>")])
    func aFailureWithoutAnErrorObjectIsNeverReportedAsSuccess(status: Int, body: String) async {
        let answer = Self.object(await Self.relay(Recorder(), reply: body, status: status)
            .forward(Self.data(["op": "automation.delete", "params": ["automation": "auto_x"], "idempotency_key": "k"])))
        #expect(answer["ok"] as? Bool == false)
        #expect((answer["error"] as? [String: Any])?["code"] as? String != nil)
    }
}
