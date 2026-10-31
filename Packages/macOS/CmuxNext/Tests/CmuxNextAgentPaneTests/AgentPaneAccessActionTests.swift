import Testing
@testable import CmuxNextAgentPane

/// A model the person cannot use (Leo 2026-10-26: "if user picks a model they don't have api key, we
/// offer them to add credits or add their own api key"): the pane's Add Credits… takes the paid-plan
/// path as the model router's paywall, on the person's fresh gesture in the pane. Add API Key… waits
/// for key plumbing (no placement makes a saved key usable yet), so Settings > Accounts stays out of
/// the pane's reach.
@MainActor
struct AgentPaneAccessActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func addCreditsTakesThePaidPlanPathAsTheModelRoutersPaywall() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return true }
        #expect(await model.respond(to: .runAction("palette.pro.upgrade"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no Checkout")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.pro.upgrade"))["ok"] as? Bool == true)
        #expect(ran == ["palette.pro.upgrade"])
        #expect(arguments == [["source": "inference"]])
    }

    @Test func accountsAndOtherAppActionsStayOutOfReach() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return true }
        for id in ["accounts.show", "accounts.remove"] {
            model.transport.gestures.record()
            #expect(await model.respond(to: .runAction(id))["ok"] as? Bool != true, "\(id)")
        }
        #expect(ran.isEmpty)
    }
}
