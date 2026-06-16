import CMUXAgentLaunch
import Testing

@Suite("Claude Teams restore flags")
struct ClaudeTeamsRestoreFlagTests {
    @Test("Preserves tmux mode and following permission flags")
    func preservesTmuxAndPermissionFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--teammate-mode",
                    "auto",
                    "--tmux",
                    "--dangerously-skip-permissions",
                    "--model",
                    "sonnet",
                    "initial prompt should not replay",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--teammate-mode",
                "auto",
                "--tmux",
                "--dangerously-skip-permissions",
                "--model",
                "sonnet",
            ]
        )
    }
}
