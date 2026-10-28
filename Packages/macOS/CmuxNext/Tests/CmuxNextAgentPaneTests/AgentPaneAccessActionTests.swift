import Testing
@testable import CmuxNextAgentPane

/// A model the person cannot use (Leo 2026-10-26: "if user picks a model they don't have api key, we
/// offer them to add credits or add their own api key"): the pane's Add API Key… opens Settings >
/// Accounts at the provider's key field, and Add Credits… takes the paid-plan path as the model
/// router's paywall. Both open app UI, so both run only on the person's fresh gesture in the pane.
@MainActor
struct AgentPaneAccessActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "action.run", "params": params])
    }

    @Test func thePageNamesOnlyAProviderBesideTheAction() {
        #expect(request(["id": "accounts.show", "provider": "anthropic"]) == .runAction("accounts.show", arguments: ["provider": "anthropic"]))
        #expect(request(["id": "accounts.show", "source": "x"]) == .runAction("accounts.show"))
        #expect(request(["id": "accounts.show", "provider": String(repeating: "a", count: 33)]) == .runAction("accounts.show"))
    }

    @Test func addAPIKeyOpensAccountsAtTheProviderOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return true }
        #expect(await model.respond(to: .runAction("accounts.show", arguments: ["provider": "anthropic"]))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no Settings window")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("accounts.show", arguments: ["provider": "anthropic"]))["ok"] as? Bool == true)
        #expect(ran == ["accounts.show"])
        #expect(arguments == [["provider": "anthropic"]])
    }

    @Test func aProviderThatIsNotANameIsDropped() async {
        let model = AgentPaneModel(host: NoHost())
        var arguments: [[String: String]] = []
        model.onRunAction = { _, args in arguments.append(args); return true }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("accounts.show", arguments: ["provider": "Anthropic Key"]))["ok"] as? Bool == true)
        #expect(arguments == [[:]], "Accounts opens at the top")
    }

    @Test func addCreditsTakesThePaidPlanPathAsTheModelRoutersPaywall() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return true }
        #expect(await model.respond(to: .runAction("palette.pro.upgrade"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no Checkout")
        model.transport.gestures.record()
        // A provider named for Add Credits… is not passed on: only the fixed source is.
        #expect(await model.respond(to: .runAction("palette.pro.upgrade", arguments: ["provider": "openai"]))["ok"] as? Bool == true)
        #expect(ran == ["palette.pro.upgrade"])
        #expect(arguments == [["source": "inference"]])
    }

    @Test func otherAppActionsStayOutOfReach() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return true }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("accounts.remove", arguments: ["provider": "openai"]))["ok"] as? Bool != true)
        #expect(ran.isEmpty)
    }
}
