import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneMachinePickerTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func inventoryIsReadOnlyAndKeepsAccountLoadingState() async {
        let model = AgentPaneModel(host: NoHost())
        model.onListMachines = { ["loaded": false, "signedIn": true, "machines": []] }
        let reply = await model.respond(to: .machineList)
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["value"] as? [String: Any])?["loaded"] as? Bool == false)
        #expect(!model.userTouched)
    }

    @Test func resumeRequiresOneGestureAndNamesTheSelectedMachine() async {
        let model = AgentPaneModel(host: NoHost())
        var ids: [String] = []
        model.onResumeMachine = { ids.append($0); return true }
        #expect(await model.respond(to: .machineResume("vm-selected"))["ok"] as? Bool != true)
        #expect(ids.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: .machineResume("vm-selected"))["ok"] as? Bool == true)
        #expect(ids == ["vm-selected"])
        #expect(await model.respond(to: .machineResume("vm-other"))["ok"] as? Bool != true)
    }

    @Test func unknownMachineRefusalIsVisible() async {
        let model = AgentPaneModel(host: NoHost())
        model.onOpenMachine = { _ in false }
        model.transport.gestures.record()
        let reply = await model.respond(to: .machineOpen("unknown"))
        #expect(reply["ok"] as? Bool != true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unavailable")
    }

    @Test func ticketPairingUsesTheExistingCodeFlow() async {
        let model = AgentPaneModel(host: NoHost())
        var actions: [String] = []
        model.onRunAction = { id, arguments in actions.append(id); #expect(arguments == ["way": "code"]); return true }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("device.add"))["ok"] as? Bool == true)
        #expect(actions == ["device.add"])
    }
}
