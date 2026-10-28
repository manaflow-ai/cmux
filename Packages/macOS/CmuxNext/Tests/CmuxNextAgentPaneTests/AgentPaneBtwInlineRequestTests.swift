import Testing
@testable import CmuxNextAgentPane

private actor NoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

@Test("native inline btw request decodes to the acpmux handler case")
func inlineBtwRequestDecodes() {
    let request = AgentPaneRequest(body: [
        "method": "chat.btw.inline",
        "params": ["question": "What changed?", "sessionId": "session-1"],
    ])
    #expect(request == .btwInline(question: "What changed?", sessionId: "session-1"))
    #expect(request.description == "btwInline")
}

@Test("native inline btw requires the authenticated user gesture")
@MainActor
func inlineBtwRequiresGesture() async {
    let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
    model.transport.acpmuxSocket = "/tmp/acpmux.sock"
    model.transport.gestures.record(click: true)
    let request = AgentPaneRequest(body: [
        "method": "chat.btw.inline",
        "params": ["question": "What changed?", "sessionId": "session-1"],
    ])

    let untrusted = await model.respond(to: request)
    #expect((untrusted["error"] as? [String: Any])?["code"] as? String == "acpmux.gesture_required")
    #expect(model.transport.gestures.isAvailable, "a non-user page call must not spend the gesture")

    let trusted = await model.respond(to: request, userGesture: true)
    #expect((trusted["error"] as? [String: Any])?["code"] as? String != "acpmux.gesture_required")
    #expect(!model.transport.gestures.isAvailable, "the inline request spends its one-use gesture")
}
