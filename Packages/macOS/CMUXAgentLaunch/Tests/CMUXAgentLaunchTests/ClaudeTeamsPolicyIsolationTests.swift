import CMUXAgentLaunch
import Testing

@Suite("Claude Teams policy isolation")
struct ClaudeTeamsPolicyIsolationTests {
    @Test("Drops equals-style tmux mode without stopping later flags")
    func dropsEqualsStyleTmuxModeWithoutStoppingLaterFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux=classic",
                    "--model",
                    "sonnet",
                    "--dangerously-skip-permissions",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--model",
                "sonnet",
                "--dangerously-skip-permissions",
            ]
        )
    }

    @Test("Drops split tmux mode without stopping later flags")
    func dropsSplitTmuxModeWithoutStoppingLaterFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "classic",
                    "--model",
                    "sonnet",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Plain Claude still drops worktree selectors")
    func plainClaudeStillDropsWorktreeSelectors() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--worktree",
                    "/tmp/repo",
                    "--model",
                    "sonnet",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "sonnet",
            ]
        )
    }
}
