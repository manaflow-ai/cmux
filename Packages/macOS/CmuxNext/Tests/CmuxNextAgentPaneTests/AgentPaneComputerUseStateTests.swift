import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The composer's `@computer-use` (CMUX-682): the App pushes Computer Use's state to every page as it
/// changes (`computerUseState`), so a send decides on it at once; when it is not ready, Set Up Computer
/// Use opens the onboarding step on the person's own key press or click in the pane.
@MainActor
struct AgentPaneComputerUseStateTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func theSetupPhaseMapsToWhatThePageHolds() {
        #expect(AgentPaneComputerUseState(phase: "ready", granted: true) == .ready)
        #expect(AgentPaneComputerUseState(phase: "ready", granted: false) == .needsSetup, "a grant is missing")
        #expect(AgentPaneComputerUseState(phase: "starting", granted: false) == .starting)
        #expect(AgentPaneComputerUseState(phase: "disabled_by_policy", granted: false) == .disabled)
        // Setup can turn it on or restart it.
        for phase in ["off", "failed"] {
            #expect(AgentPaneComputerUseState(phase: phase, granted: false) == .needsSetup, "\(phase)")
        }
        // No cmux Remote in this build, or one of another version: setup cannot fix it (#48541).
        for phase in ["unavailable", "version_mismatch"] {
            #expect(AgentPaneComputerUseState(phase: phase, granted: false) == .unavailable, "\(phase)")
        }
    }

    @Test func thePageGetsTheStateAsItsRawValueAndNullWhileUnknown() {
        #expect(AgentPageEvent.computerUseState(.needsSetup).kind == "computerUseState")
        #expect(AgentPageEvent.computerUseState(.needsSetup).value == .string("needs_setup"))
        #expect(AgentPageEvent.computerUseState(.ready).value == .string("ready"))
        #expect(AgentPageEvent.computerUseState(.unavailable).value == .string("unavailable"))
        #expect(AgentPageEvent.computerUseState(nil).value == .null)
    }

    @Test func theFollowerKeepsTheLatestState() {
        let follower = AgentPaneComputerUse(read: nil)
        #expect(follower.state == nil)
        follower.set(.needsSetup)
        #expect(follower.state == .needsSetup)
        follower.set(.ready)
        #expect(follower.state == .ready)
    }

    /// The pane's own WebKit host (dev-server panes, the bundled WebKit fallback) has no page host
    /// replay: its page gets the state at each handshake (AgentPaneBridge `ready`) and every later
    /// change, as a script, never nothing (the page sends while it knows no state).
    @Test func thePanesOwnWebKitHostGetsTheStateAtItsHandshakeAndOnEveryChange() async throws {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: NoHost())
        let follower = AgentPaneComputerUse(read: nil)
        model.computerUse = follower
        let view = try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null"))))
        try #require(view.pageEvents == nil, "setup: not the pane's own WebKit host")
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        let pushes = { scripts.filter { $0.hasPrefix("window.cmuxAcpmuxComputerUseState?.(") } }
        follower.set(.needsSetup)
        #expect(pushes().isEmpty, "a page that never shook hands was told")

        _ = await AgentPaneBridge(view: view).reply(to: .ready)
        #expect(pushes() == [AgentPaneComputerUse.script(.computerUseState(.needsSetup))])
        #expect(pushes().last == "window.cmuxAcpmuxComputerUseState?.(\"needs_setup\");")

        follower.set(.ready)
        #expect(pushes().last == "window.cmuxAcpmuxComputerUseState?.(\"ready\");", "a change missed the page")
        // A reloaded document shakes hands again and gets the state as it is now.
        _ = await AgentPaneBridge(view: view).reply(to: .ready)
        #expect(pushes().count == 3 && pushes().last == AgentPaneComputerUse.script(.computerUseState(.ready)))
        view.close()
    }

    @Test func thePaneNoLongerAnswersAStateQuery() {
        // The page no longer asks: the state comes as a push.
        let request = AgentPaneRequest(body: ["method": "chat.computerUse.state", "params": [String: Any]()])
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
