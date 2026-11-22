import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `action.run` of the location row's connect flows (SSH… `remote.connect`, cmux Cloud…
/// `newCloudMachine`, #18143) opens app UI from page script, so it needs the user's fresh gesture
/// in the pane, the same grant credit as Choose Folder… and shell mode. The signed-out sign-in
/// fallback runs only inside that same gesture.
@MainActor
@Suite(.serialized) struct AgentPaneConnectActionGestureTests {
    @Test func pageScriptWithoutAGestureCannotRunTheConnectFlowsOrSignIn() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var actions: [String] = []
        model.onRunAction = { actions.append($0); return $0 != "newCloudMachine" }
        for id in AgentPaneModel.connectActions.sorted() {
            let reply = await model.respond(to: .runAction(id))
            #expect(reply["ok"] as? Bool == false, "\(id)")
            #expect((reply["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue, "\(id)")
        }
        #expect(actions.isEmpty)
    }

    @Test func oneGestureRunsOneConnectFlowAndItsSignInFallback() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var actions: [String] = []
        model.onRunAction = { actions.append($0); return $0 != "newCloudMachine" }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("newCloudMachine"))["ok"] as? Bool == true)
        #expect(actions == ["newCloudMachine", "palette.auth.signIn"])
        // The gesture is spent: the next connect needs a new one.
        #expect(await model.respond(to: .runAction("remote.connect"))["ok"] as? Bool == false)
        #expect(actions == ["newCloudMachine", "palette.auth.signIn"])
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("remote.connect"))["ok"] as? Bool == true)
        #expect(actions == ["newCloudMachine", "palette.auth.signIn", "remote.connect"])
    }
}
