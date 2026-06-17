import CMUXAgentLaunch
import Testing

@Suite("Claude Teams optional values")
struct ClaudeTeamsOptionalValueTests {
    @Test("Preserves split worktree values with spaces before later flags")
    func preservesSplitWorktreeValuesWithSpacesBeforeLaterFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--worktree",
                    "/tmp/team repo",
                    "--model",
                    "sonnet",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--worktree",
                "/tmp/team repo",
                "--model",
                "sonnet",
            ]
        )
    }
}
