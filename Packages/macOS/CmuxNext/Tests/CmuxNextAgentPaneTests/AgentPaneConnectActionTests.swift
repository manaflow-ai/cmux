import Testing
@testable import CmuxNextAgentPane

/// The location row's connect choices (``AgentPaneModel/runAction(_:)``): SSH…, New Cloud Machine
/// and Choose Machine Size… (the Cloud page, whose storefront lists the plan's sizes) run their app
/// action on the person's fresh gesture in the pane, never on page script alone.
@MainActor
struct AgentPaneConnectActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func chooseMachineSizeOpensTheCloudPageOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id in ran.append(id); return true }
        #expect(await model.respond(to: .runAction("palette.openCloudPane"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no page")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.openCloudPane"))["ok"] as? Bool == true)
        #expect(ran == ["palette.openCloudPane"])
    }
}
