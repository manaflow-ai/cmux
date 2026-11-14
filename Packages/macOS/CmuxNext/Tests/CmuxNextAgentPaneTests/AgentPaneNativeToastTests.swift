import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
import Testing

private actor NoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

/// The agent pane's feedback toasts are the app's native toasts (Lawrence 2026-11-13: one toast style,
/// picked in the Toast Playground, for every toast): the page sends `pane.toast`, and the pane shows it
/// through the shared toast center, an error as an error.
@MainActor
@Suite struct AgentPaneNativeToastTests {
    @Test func aPaneToastDecodesAndBadOnesAreRefused() {
        #expect(AgentPaneRequest(body: ["id": "t", "method": "pane.toast", "params": ["message": "Copied", "tone": "neutral", "group": "copy"]])
            == .toast(message: "Copied", isError: false, group: "copy"))
        #expect(AgentPaneRequest(body: ["id": "t", "method": "pane.toast", "params": ["message": "Could not open", "tone": "error"]])
            == .toast(message: "Could not open", isError: true, group: nil))
        #expect(AgentPaneRequest(body: ["id": "t", "method": "pane.toast", "params": ["message": ""]]) == .unsupported("pane.toast"))
        #expect(AgentPaneRequest(body: ["id": "t", "method": "pane.toast", "params": [:]]) == .unsupported("pane.toast"))
    }

    @Test func aPaneToastShowsThroughTheSharedCenter() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-a")
        var shown: [CmuxToast] = []
        model.onToast = { shown.append($0) }
        _ = await model.respond(to: .toast(message: "Could not open", isError: true, group: "feedback"))
        #expect(shown.map(\.message) == ["Could not open"])
        #expect(shown.first?.tone == .error)
        #expect(shown.first?.kind == "agentPane.feedback")
    }
}
