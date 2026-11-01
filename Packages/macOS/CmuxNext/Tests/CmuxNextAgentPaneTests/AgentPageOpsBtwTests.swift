import Testing
@testable import CmuxNextAgentPane

@Test("inline btw action is registered in the native agent page allowlist")
func inlineBtwActionIsAllowlisted() {
    #expect(AgentPageOps.methods["chat.btw.inline"] == "chat.btw.inline")
    #expect(AgentPageOps.all.contains("cmux.agent.chat.btw.inline"))
}
