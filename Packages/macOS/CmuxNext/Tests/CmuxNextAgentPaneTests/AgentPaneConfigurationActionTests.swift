import Testing
@testable import CmuxNextAgentPane

@Suite
struct AgentPaneConfigurationActionTests {
    @Test func modelUsesModelId() {
        #expect(AgentPaneConfigurationOperation.model.payloadKey == "modelId")
        #expect(AgentPaneConfigurationOperation.model.payload(value: "gpt-6-astra", sessionID: "a") == [
            "modelId": "gpt-6-astra", "expectedSessionId": "a",
        ])
    }

    @Test func effortUsesTheHarnessResolvedEffortKey() {
        #expect(AgentPaneConfigurationOperation.effort.payloadKey == "effort")
        #expect(AgentPaneConfigurationOperation.effort.payload(value: "high", sessionID: nil) == ["effort": "high"])
    }

    @Test func modeUsesModeId() {
        #expect(AgentPaneConfigurationOperation.mode.payloadKey == "modeId")
        #expect(AgentPaneConfigurationOperation.mode.payload(value: "plan", sessionID: "b") == [
            "modeId": "plan", "expectedSessionId": "b",
        ])
    }
}
