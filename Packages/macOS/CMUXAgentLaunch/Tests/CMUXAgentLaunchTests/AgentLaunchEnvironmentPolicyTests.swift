import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchEnvironmentPolicy")
struct AgentLaunchEnvironmentPolicyTests {
    @Test("Preserves Claude Bedrock routing without persisting AWS secrets")
    func preservesClaudeBedrockRoutingWithoutPersistingAWSSecrets() {
        let selected = AgentLaunchEnvironmentPolicy.selectedEnvironment(
            from: [
                "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                "ANTHROPIC_BEDROCK_BASE_URL": "https://bedrock-runtime.us-west-2.amazonaws.com",
                "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
                "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
                "AWS_ACCESS_KEY_ID": "key-should-not-persist",
                "AWS_PROFILE": "bedrock-prod",
                "AWS_REGION": "us-west-2",
                "AWS_SECRET_ACCESS_KEY": "secret-should-not-persist",
                "AWS_SESSION_TOKEN": "token-should-not-persist",
                "CLAUDE_CODE_USE_BEDROCK": "1",
            ],
            kind: "claude"
        )

        #expect(selected == [
            "ANTHROPIC_BEDROCK_BASE_URL": "https://bedrock-runtime.us-west-2.amazonaws.com",
            "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
            "AWS_PROFILE": "bedrock-prod",
            "AWS_REGION": "us-west-2",
            "CLAUDE_CODE_USE_BEDROCK": "1",
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
