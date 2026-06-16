import CMUXAgentLaunch
import Testing

@Suite("Claude Teams prompt boundary recovery")
struct ClaudeTeamsPromptBoundaryRecoveryTests {
    @Test("Recovers restore-safe flags after tmux payload when followed by prompt")
    func recoversRestoreSafeFlagsAfterTmuxPayloadWhenFollowedByPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "side effect should be dropped",
                    "--permission-mode",
                    "auto",
                    "initial team prompt",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--permission-mode",
                "auto",
            ]
        )
    }
}
