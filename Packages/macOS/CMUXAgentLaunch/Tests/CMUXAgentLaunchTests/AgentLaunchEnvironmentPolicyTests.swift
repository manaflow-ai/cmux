import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchEnvironmentPolicy")
struct AgentLaunchEnvironmentPolicyTests {
    @Test("Preserves OMP config roots without persisting secrets")
    func preservesOmpConfigRootsWithoutPersistingSecrets() {
        let selected = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: [
                "OPENAI_API_KEY": "secret-should-not-persist",
                "PI_CODING_AGENT_DIR": "/tmp/omp-agent",
                "PI_CONFIG_DIR": ".custom-omp",
            ],
            kind: "omp"
        )

        #expect(selected == [
            "PI_CODING_AGENT_DIR": "/tmp/omp-agent",
            "PI_CONFIG_DIR": ".custom-omp",
        ])
    }

    @Test("Preserves Safari MCP path controls without persisting secrets")
    func preservesSafariMCPPathControlsWithoutPersistingSecrets() {
        let selected = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: [
                "CMUX_SAFARI_MCP_DISABLED": "1",
                "CMUX_SAFARI_MCP_DRIVER_PATH": "/tmp/Safari Technology Preview.app/safaridriver",
                "SAFARI_MCP_TOKEN": "secret-should-not-persist",
            ],
            kind: "codex"
        )

        #expect(selected == [
            "CMUX_SAFARI_MCP_DISABLED": "1",
            "CMUX_SAFARI_MCP_DRIVER_PATH": "/tmp/Safari Technology Preview.app/safaridriver",
        ])
    }
}
