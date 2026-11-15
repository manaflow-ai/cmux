@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// Toggle Terminal and Chat's approval on the chat face: the page gets the terminal's dialog as a
/// `terminalApproval` event, and a click (`chat.terminalApproval.answer {key, label, question}`) reaches
/// the App only for an option of the dialog shown, with the person's own gesture.
@MainActor
struct AgentPaneTerminalApprovalTests {
    let approval = AgentPaneTerminalApproval(
        question: "Do you want to proceed?", header: "Bash command", command: "touch /tmp/x", detail: ["Make a marker"],
        options: [.init(key: 1, label: "Yes", kind: "allow_once"), .init(key: 2, label: "No", kind: "reject_once")])

    @Test func theAnswerDecodesAndAMalformedOneIsRefused() {
        let params: [String: Any] = ["key": 2, "label": "No", "question": "Do you want to proceed?"]
        #expect(AgentPaneRequest(body: ["method": "chat.terminalApproval.answer", "params": params])
            == .terminalApproval(.init(key: 2, label: "No", question: "Do you want to proceed?")))
        for bad: [String: Any] in [[:], ["key": 0, "label": "No", "question": "Q?"], ["key": 2, "label": "", "question": "Q?"],
                                   ["key": 2, "label": "No"], ["key": 2, "label": "No", "question": "Q?", "extra": true]] {
            #expect(AgentPaneRequest(body: ["method": "chat.terminalApproval.answer", "params": bad]) == .unsupported("chat.terminalApproval.answer"))
        }
        #expect(AgentPageOps.all.contains(AgentPageOps.namespace + "chat.terminalApproval.answer"))
    }

    @Test func thePageGetsTheDialogOrNull() {
        let event = AgentPageEvent.terminalApproval(approval)
        #expect(event.kind == "terminalApproval")
        #expect(event.value == [
            "question": "Do you want to proceed?", "header": "Bash command", "command": "touch /tmp/x", "detail": ["Make a marker"],
            "options": [["key": .number(1), "label": "Yes", "kind": "allow_once"], ["key": .number(2), "label": "No", "kind": "reject_once"]],
        ])
        #expect(AgentPageEvent.terminalApproval(nil).value == .null)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pick types into a terminal, so it needs the person's own click, and only an option shown.
    @Test func aPickNeedsTheGestureAndAShownOption() async {
        let model = AgentPaneModel(host: NoHost())
        var picks: [AgentPaneTerminalApproval.Pick] = []
        model.onTerminalApproval = { picks.append($0); return true }
        model.terminalApproval = approval
        let request = AgentPaneRequest(body: ["method": "chat.terminalApproval.answer",
                                              "params": ["key": 2, "label": "No", "question": "Do you want to proceed?"]])
        let unasked = await model.respond(to: request)
        #expect((unasked["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        model.transport.gestures.record(click: true)
        let other = AgentPaneRequest(body: ["method": "chat.terminalApproval.answer",
                                            "params": ["key": 2, "label": "Yes", "question": "Do you want to proceed?"]])
        #expect((await model.respond(to: other))["error"] != nil, "an option the card does not show")
        #expect(picks.isEmpty)
        let clicked = await model.respond(to: request)
        #expect(clicked["error"] == nil)
        #expect(picks == [.init(key: 2, label: "No", question: "Do you want to proceed?")])
        model.onTerminalApproval = { _ in false }
        model.transport.gestures.record(click: true)
        #expect(((await model.respond(to: request))["error"] as? [String: Any])?["code"] as? String == "terminal_changed")
    }
}
