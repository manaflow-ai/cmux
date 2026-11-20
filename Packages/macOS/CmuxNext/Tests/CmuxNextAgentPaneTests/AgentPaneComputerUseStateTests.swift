import Testing
@testable import CmuxNextAgentPane

/// The composer's `@computer-use` (CMUX-682): the page asks whether Computer Use is set up
/// (`chat.computerUse.state`) and, when it is not, offers Set Up Computer Use, which opens the
/// onboarding step on the person's own click in the pane.
@MainActor
struct AgentPaneComputerUseStateTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let ask: [String: Any] = ["method": "chat.computerUse.state", "params": [String: Any]()]

    @Test func thePageReadsTheAppsAnswerAndAnOldHostSaysUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        let unanswered = await model.respond(to: AgentPaneRequest(body: Self.ask))
        #expect(unanswered["ok"] as? Bool != true, "no App answer: the page holds nothing")
        for state in [AgentPaneComputerUseState.ready, .starting, .needsSetup, .disabled] {
            model.onComputerUseState = { state }
            let reply = await model.respond(to: AgentPaneRequest(body: Self.ask))
            #expect(reply["ok"] as? Bool == true)
            #expect((reply["value"] as? [String: Any])?["state"] as? String == state.rawValue)
        }
        #expect(AgentPaneComputerUseState.needsSetup.rawValue == "needs_setup")
    }

    @Test func theSetupPhaseMapsToWhatThePageHolds() {
        #expect(AgentPaneComputerUseState(phase: "ready", granted: true) == .ready)
        #expect(AgentPaneComputerUseState(phase: "ready", granted: false) == .needsSetup, "a grant is missing")
        #expect(AgentPaneComputerUseState(phase: "starting", granted: false) == .starting)
        #expect(AgentPaneComputerUseState(phase: "disabled_by_policy", granted: false) == .disabled)
        for phase in ["off", "unavailable", "failed", "version_mismatch"] {
            #expect(AgentPaneComputerUseState(phase: phase, granted: false) == .needsSetup, "\(phase)")
        }
    }

    @Test func paramsAreRefused() {
        let request = AgentPaneRequest(body: ["method": "chat.computerUse.state", "params": ["state": "ready"]])
        #expect(request == .unsupported("chat.computerUse.state"))
    }

    @Test func setUpComputerUseRunsOnlyOnThePersonsGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return .ran }
        #expect(await model.respond(to: .runAction(AgentPaneComputerUseState.setupAction))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no onboarding step")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction(AgentPaneComputerUseState.setupAction))["ok"] as? Bool == true)
        #expect(ran == ["palette.computerUse.setup"])
        // The Settings card's other Computer Use actions stay out of the pane's reach.
        for id in ["palette.computerUse.restart", "palette.computerUse.accessibility", "computerUse.approval.set"] {
            model.transport.gestures.record()
            #expect(await model.respond(to: .runAction(id))["ok"] as? Bool != true, "\(id)")
        }
        #expect(ran == ["palette.computerUse.setup"])
    }
}
