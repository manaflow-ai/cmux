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
}
