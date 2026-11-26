import Testing
@testable import CmuxNextAgentPane

/// The model picker's "Set up more for Cloud…" row with Cloud picked (cmux#51731): Open Settings on Settings > Cloud,
/// on the person's gesture in the pane. The page cannot pick another Settings place: the route is the app's.
@MainActor
struct AgentPaneCloudSettingsActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func setUpMoreForCloudOpensSettingsCloudOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return .ran }
        #expect(await model.respond(to: .runAction("openSettings"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no Settings")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("openSettings"))["ok"] as? Bool == true)
        #expect(ran == ["openSettings"])
        #expect(arguments == [["route": "#/settings/cloud"]])
    }
}
