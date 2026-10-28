import Testing
@testable import CmuxNextAgentPane

@Test("native inline btw request decodes to the acpmux handler case")
func inlineBtwRequestDecodes() {
    let request = AgentPaneRequest(body: [
        "method": "chat.btw.inline",
        "params": ["question": "What changed?", "sessionId": "session-1"],
    ])
    #expect(request == .btwInline(question: "What changed?", sessionId: "session-1"))
    #expect(request.description == "btwInline")
}
