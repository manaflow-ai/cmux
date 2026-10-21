import Testing
@testable import CmuxNextAgentPane

/// The location row's connect choices (``AgentPaneModel/runAction(_:)``): SSH…, New Cloud Machine
/// and Open Cloud… (the Cloud page at its storefront, `#/get`, which lists the plan's sizes) run their
/// app action on the person's fresh gesture in the pane, never on page script alone.
@MainActor
struct AgentPaneConnectActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func openCloudOpensTheCloudStorefrontOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return true }
        #expect(await model.respond(to: .runAction("palette.openCloudPane"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no page")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.openCloudPane"))["ok"] as? Bool == true)
        #expect(ran == ["palette.openCloudPane"])
        #expect(arguments == [["route": "/get"]], "Open Cloud… lands on the storefront, not the machine list")
    }

    @Test func otherConnectActionsRunWithoutArguments() async {
        let model = AgentPaneModel(host: NoHost())
        var arguments: [[String: String]] = []
        model.onRunAction = { _, args in arguments.append(args); return true }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("newCloudMachine"))["ok"] as? Bool == true)
        #expect(arguments == [[:]])
    }
}
