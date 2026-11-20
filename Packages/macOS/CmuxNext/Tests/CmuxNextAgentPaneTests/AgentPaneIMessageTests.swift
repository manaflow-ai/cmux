import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneIMessageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func connectionAndPermissionActionsRequireThePersonsGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var called: [AgentPaneIMessageAction] = []
        model.onIMessage = { action in called.append(action); return AgentPaneReply.success() }
        for action in AgentPaneIMessageAction.allCases where !action.isPassive {
            let request = AgentPaneRequest.imessage(action)
            #expect(await model.respond(to: request)["ok"] as? Bool == false)
            model.transport.gestures.record(click: true)
            #expect(await model.respond(to: request)["ok"] as? Bool == true)
            #expect(await model.respond(to: request)["ok"] as? Bool == false)
        }
        #expect(called == AgentPaneIMessageAction.allCases.filter { !$0.isPassive })
    }

    @Test func statusAndThreadsArePassiveButThereIsNoSendOperation() async {
        let model = AgentPaneModel(host: NoHost())
        var called: [AgentPaneIMessageAction] = []
        model.onIMessage = { action in called.append(action); return AgentPaneReply.success() }
        for action in [AgentPaneIMessageAction.status, .threads] {
            let method = "imessage.\(action.rawValue)"
            #expect(AgentPageOps.methods[method] == method)
            #expect(await model.respond(to: AgentPaneRequest(body: ["method": method]))["ok"] as? Bool == true)
        }
        #expect(called == [.status, .threads])
        #expect(!model.userTouched)
        #expect(AgentPaneRequest(body: ["method": "imessage.send"]) == .unsupported("imessage.send"))
        #expect(AgentPageOps.methods["imessage.send"] == nil)
    }
}
