import CMUXAgentLaunch
import Testing

@Suite("ClaudeSecureStorageConfigDirectoryPolicy")
struct ClaudeSecureStorageConfigDirectoryPolicyTests {
    @Test("Preserves Claude secure storage config dir on capture")
    func preservesClaudeSecureStorageConfigDirectory() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: [
                "CLAUDE_CONFIG_DIR": "/tmp/claude-work",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/claude-work-credentials",
                "ANTHROPIC_AUTH_TOKEN": "secret-should-not-persist",
            ],
            kind: "claude"
        )

        #expect(selected["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/claude-work-credentials")
        #expect(selected["ANTHROPIC_AUTH_TOKEN"] == nil)
    }

    @Test("Passes Claude secure storage config dir through sanitizedValue unchanged")
    func sanitizesClaudeSecureStorageConfigDirectory() {
        let policy = AgentLaunchEnvironmentPolicy()
        #expect(
            policy.sanitizedValue(
                key: "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                value: "/tmp/claude-work-credentials"
            ) == "/tmp/claude-work-credentials"
        )
    }
}
