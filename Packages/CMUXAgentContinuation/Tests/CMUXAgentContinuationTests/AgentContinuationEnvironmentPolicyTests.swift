import CMUXAgentContinuation
import Testing

@Suite("AgentContinuationEnvironmentPolicy")
struct AgentContinuationEnvironmentPolicyTests {
    @Test("Codex keeps CODEX_HOME and drops Claude account environment")
    func codexKeepsCodexHomeAndDropsClaudeAccountEnvironment() {
        let selected = AgentContinuationEnvironmentPolicy.selectedEnvironment(
            from: [
                "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                "CLAUDE_CONFIG_DIR": "/Users/example/.codex-accounts/claude/_p1781081935106",
                "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
                "OPENAI_API_KEY": "secret",
            ],
            kind: "codex"
        )

        #expect(selected == [
            "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
        ])
    }

    @Test("Wrapper launcher names use the underlying agent environment policy")
    func wrapperLauncherNamesUseUnderlyingAgentEnvironmentPolicy() {
        let codexTeams = AgentContinuationEnvironmentPolicy.selectedEnvironment(
            from: [
                "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                "CLAUDE_CONFIG_DIR": "/Users/example/.codex-accounts/claude/_p1781081935106",
                "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
            ],
            kind: "codexTeams"
        )
        let openCodeAlias = AgentContinuationEnvironmentPolicy.selectedEnvironment(
            from: [
                "OPENCODE_CONFIG_DIR": "/Users/example/.opencode-alt",
                "CLAUDE_CONFIG_DIR": "/Users/example/.claude",
            ],
            kind: "omo"
        )

        #expect(codexTeams == [
            "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
        ])
        #expect(openCodeAlias == [
            "OPENCODE_CONFIG_DIR": "/Users/example/.opencode-alt",
        ])
    }

    @Test("Cursor keeps config roots without persisting auth")
    func cursorKeepsConfigRootsWithoutPersistingAuth() {
        let selected = AgentContinuationEnvironmentPolicy.selectedEnvironment(
            from: [
                "CURSOR_CONFIG_DIR": "/Users/example/.cursor-alt",
                "CURSOR_AGENT_HOME": "/Users/example/.cursor-agent",
                "CURSOR_HOME": "/Users/example/.cursor-home",
                "CURSOR_API_KEY": "secret",
                "OPENAI_API_KEY": "secret",
            ],
            kind: "cursor"
        )

        #expect(selected == [
            "CURSOR_AGENT_HOME": "/Users/example/.cursor-agent",
            "CURSOR_CONFIG_DIR": "/Users/example/.cursor-alt",
            "CURSOR_HOME": "/Users/example/.cursor-home",
        ])
    }

    @Test("Antigravity keeps Gemini home without persisting auth")
    func antigravityKeepsGeminiHomeWithoutPersistingAuth() {
        let selected = AgentContinuationEnvironmentPolicy.selectedEnvironment(
            from: [
                "GEMINI_CLI_HOME": "/Users/example/.gemini-alt",
                "GEMINI_API_KEY": "secret",
            ],
            kind: "antigravity"
        )

        #expect(selected == [
            "GEMINI_CLI_HOME": "/Users/example/.gemini-alt",
        ])
    }

    @Test("Claude keeps Claude environment and drops Codex home")
    func claudeKeepsClaudeEnvironmentAndDropsCodexHome() {
        let selected = AgentContinuationEnvironmentPolicy.selectedEnvironment(
            from: [
                "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                "CLAUDE_CONFIG_DIR": "/Users/example/.codex-accounts/claude/_p1781081935106",
                "CODEX_HOME": "/Users/example/.codex-accounts/codex/_p1781081935106",
            ],
            kind: "claude"
        )

        #expect(selected == [
            "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
            "CLAUDE_CONFIG_DIR": "/Users/example/.codex-accounts/claude/_p1781081935106",
        ])
    }
}
