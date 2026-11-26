import Foundation
import Testing
@testable import CmuxNextAgentPane

/// "Fork first" on a risky step of a Cloud chat (``AgentPaneForkFirst``): the page's ask decodes only
/// whole, and the allow's ticket the click paid for outlives the fork (30 to 60 s, past a ticket's
/// 60 s) only because its clock starts again when the fork answers.
@Suite(.serialized)
@MainActor
struct AgentPaneForkFirstTests {
    private let params: [String: Any] = [
        "sessionId": "s1", "permissionId": "p1", "optionId": "yes", "machine": "vm_abc", "clientKey": "risky-p1",
    ]

    @Test func theAskDecodesOnlyWhole() throws {
        let fork = try #require(AgentPaneForkFirst(params: params))
        #expect(AgentPaneRequest(body: ["method": "cloud.forkFirst", "params": params]) == .cloudForkFirst(fork))
        #expect(fork.machine == "vm_abc" && fork.clientKey == "risky-p1")
        for key in params.keys {
            var missing = params
            missing.removeValue(forKey: key)
            #expect(AgentPaneRequest(body: ["method": "cloud.forkFirst", "params": missing]) == .unsupported("cloud.forkFirst"))
        }
        var path = params
        path["machine"] = "../v1/teams"
        #expect(AgentPaneForkFirst(params: path) == nil)
        #expect(fork.intent?.method == "_acpmux/permission_respond")
    }

    @Test func theAllowsTicketLivesThroughTheForkOnlyWhenRenewed() throws {
        var clock: TimeInterval = 0
        let gestures = AgentPaneUserGestures(now: { clock })
        let intent = try #require(AgentPaneForkFirst(params: params)?.intent)
        let pick = AgentPaneGesturePick(method: "_acpmux/permission_respond",
                                        params: ["sessionId": "s1", "permissionId": "p1", "optionId": "yes"])
        let renewed = try #require(gestures.reserve(connection: 1, intent: intent, paid: true))
        clock += 55
        #expect(gestures.renew(renewed))
        clock += 55
        #expect(gestures.redeem(renewed, connection: 1, pick: pick, sessionId: "s1"))

        let stale = try #require(gestures.reserve(connection: 1, intent: intent, paid: true))
        clock += 110
        #expect(!gestures.redeem(stale, connection: 1, pick: pick, sessionId: "s1"))

        let dropped = try #require(gestures.reserve(connection: 1, intent: intent, paid: true))
        gestures.drop(dropped)
        #expect(!gestures.renew(dropped))
        #expect(!gestures.redeem(dropped, connection: 1, pick: pick, sessionId: "s1"))
    }

    @Test func theAppSideAnswersTheCopyOnlyForThePanesMachine() async throws {
        let fork = try #require(AgentPaneForkFirst(params: params))
        let ok = await fork.run(still: { true }) { "vm_copy1" }
        #expect(ok["ok"] as? Bool == true)
        #expect((ok["value"] as? [String: Any])?["fork"] as? String == "vm_copy1")
        #expect((ok["value"] as? [String: Any])?["forkMs"] is Int)
        var called = false
        let elsewhere = await fork.run(still: { false }) { called = true; return "vm_copy1" }
        #expect(elsewhere["ok"] as? Bool == false && !called)
        for answer in [nil, "vm_abc", "../x"] as [String?] {
            let bad = await fork.run(still: { true }) { answer }
            #expect(bad["ok"] as? Bool == false)
        }
        struct Refused: Error {}
        let refused = await fork.run(still: { true }) { throw Refused() }
        #expect(refused["ok"] as? Bool == false)
    }
}
