import CMUXAgentLaunch
import Testing

/// Claude Code refuses to resume a session started in Code Mode unless
/// `CLAUDE_CODE_EXPERIMENTAL_CODE_MODE` is set again ("This session was started
/// in Code Mode (experimental), which is off, so it can't be resumed."), so a
/// restored Code Mode pane has to replay the flag it was launched with.
@Suite("ClaudeCodeModeEnvironmentPolicy")
struct ClaudeCodeModeEnvironmentPolicyTests {
    private let key = "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE"

    @Test("Captures the Code Mode flag from a Claude launch")
    func capturesCodeModeFlag() {
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: [key: "1", "ANTHROPIC_AUTH_TOKEN": "secret-should-not-persist"],
            kind: "claude"
        )

        #expect(selected[key] == "1")
        #expect(selected["ANTHROPIC_AUTH_TOKEN"] == nil)
    }

    @Test("Replays the Code Mode flag in a Claude resume command")
    func replaysCodeModeFlag() {
        let selected = AgentLaunchEnvironmentPolicy().selectedReplayEnvironment(
            from: [key: "1"],
            kind: "claude",
            launcher: "claude",
            arguments: ["claude"]
        )

        #expect(selected[key] == "1")
    }

    @Test("Hook producers capture the Code Mode flag")
    func hookProducersCaptureCodeModeFlag() {
        #expect(AgentLaunchEnvironmentPolicy().inputEnvironmentKeys.contains(key))
    }
}
