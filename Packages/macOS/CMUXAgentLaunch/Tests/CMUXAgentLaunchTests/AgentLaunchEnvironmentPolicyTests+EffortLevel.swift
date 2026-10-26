import CMUXAgentLaunch
import Testing

extension AgentLaunchEnvironmentPolicyTests {
    @Test func recordsAKnownEffortLevel() {
        #expect(
            AgentLaunchEnvironmentPolicy().sanitizedValue(key: "CLAUDE_CODE_EFFORT_LEVEL", value: "xhigh") == "xhigh"
        )
    }

    @Test func dropsAnUnknownEffortLevel() {
        let policy = AgentLaunchEnvironmentPolicy()
        #expect(policy.sanitizedValue(key: "CLAUDE_CODE_EFFORT_LEVEL", value: "auto") == nil)
        #expect(policy.sanitizedValue(key: "CLAUDE_CODE_EFFORT_LEVEL", value: "high; echo") == nil)
    }

    @Test func selectedEnvironmentKeepsTheEffortLevel() {
        let env = ["CLAUDE_CODE_EFFORT_LEVEL": "low", "FOO": "1"]
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: env, kind: "claude")
        #expect(selected["CLAUDE_CODE_EFFORT_LEVEL"] == "low")
    }
}
