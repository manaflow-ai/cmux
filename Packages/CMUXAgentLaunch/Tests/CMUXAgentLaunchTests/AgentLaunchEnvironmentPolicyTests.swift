import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchEnvironmentPolicy")
struct AgentLaunchEnvironmentPolicyTests {
    @Test("Codex continuation preserves CODEX_HOME without Claude account environment")
    func codexContinuationPreservesCodexHomeWithoutClaudeAccountEnvironment() {
        let selected = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: [
                "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                "CLAUDE_CONFIG_DIR": "/Users/example/.codex-accounts/claude/_p1781081935106",
                "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
                "OPENAI_API_KEY": "secret-should-not-persist",
            ],
            kind: "codex"
        )

        #expect(selected == [
            "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
        ])
    }

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
}
