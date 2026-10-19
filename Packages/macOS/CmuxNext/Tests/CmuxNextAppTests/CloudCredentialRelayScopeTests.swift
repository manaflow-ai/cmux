import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite struct CloudCredentialRelayScopeTests {
    private actor World {
        let change: String
        var team = "team_a"
        private(set) var posts = 0
        init(_ change: String) { self.change = change }
        func session() -> CloudCredentialRelay.Session { .init(signedIn: true, team: team) }
        func token() -> String {
            if change == "mint" { team = "team_b" }
            return "token-for-\(team)"
        }
        func post(_ bearer: String) -> (status: Int, body: Data) {
            posts += 1
            if change == "reply" || change == "retry" { team = "team_b" }
            if change == "retry", posts == 1 { return (401, Data(#"{"code":"auth.unauthenticated"}"#.utf8)) }
            return (200, Data(#"{"ok":true,"value":{"id":"vm_test"}}"#.utf8))
        }
    }

    private func answer(_ world: World) async -> CloudCredentialRelay.Answer {
        let relay = CloudCredentialRelay(post: { _, _, token in await world.post(token) }, token: { await world.token() },
            invalidate: {}, session: { await world.session() }, allowedOps: { ["cloud.machine.create"] })
        return await relay.answer(AppsProviderCall(requestID: 1, app: CloudCredentialRelay.app, origin: "script",
            op: CloudCredentialRelay.relayOp, params: .object(["op": .string("cloud.machine.create"),
                "idempotency_key": .string("create-1"), "params": .object([:])])))
    }

    @Test(arguments: ["mint", "reply", "retry"])
    func aSelectionChangeNeverRetargetsOrReturnsThePreviousTeamsOperation(change: String) async {
        let world = World(change), result = await answer(world)
        #expect(!result.ok)
        #expect(result.body["code"]?.stringValue == "credential.session_changed")
        #expect(await world.posts == (change == "mint" ? 0 : 1))
    }

    @Test func anUnchangedSelectionCanStillCreate() async {
        let world = World("none"), result = await answer(world)
        #expect(result.ok)
        #expect(await world.posts == 1)
    }
    @Test(arguments: [nil, "b" + String(repeating: "a", count: 63), String(repeating: "a", count: 64)])
    func aParentRequiresTheOriginalRequestContextBeforeMinting(expected: String?) async {
        let world = World("none"), scope = String(repeating: "a", count: 64)
        let relay = CloudCredentialRelay(post: { _, _, token in await world.post(token) }, token: { await world.token() },
            invalidate: {}, session: { .init(signedIn: true, team: "team_a", scope: scope, requiresScope: true) }, allowedOps: { ["cloud.machine.create"] })
        var params: [String: JSONValue] = ["op": .string("cloud.machine.create"), "params": .object([:]), "idempotency_key": .string("scoped")]
        if let expected { params["expected_scope"] = .string(expected) }
        let result = await relay.answer(AppsProviderCall(requestID: 1, app: CloudCredentialRelay.app, origin: "script",
            op: CloudCredentialRelay.relayOp, params: .object(params)))
        #expect(result.ok == (expected == scope))
        #expect(await world.posts == (expected == scope ? 1 : 0))
    }

    @Test func aScopedRunPreservesVerbatimArgsOnTheActualDaemonWire() throws {
        let scope = String(repeating: "a", count: 64), args: JSONValue = .object(["machineID": .string("vm_test")])
        let request = AppsScopedRunRequest(.init(app: "cmux/cloud", op: "cloud.machine.create", args: args,
            idempotencyKey: "create", origin: .user), expectedScope: scope)
        let line = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 4))
        #expect(line["cmd"]?.stringValue == "apps-run-scoped")
        #expect(line["expected_scope"]?.stringValue == scope)
        #expect(line["idempotency_key"]?.stringValue == "create")
        #expect(line["args"] == args)
    }

}
