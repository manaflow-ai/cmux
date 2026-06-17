import CMUXAgentLaunch
import Testing

@Suite("Claude Teams policy isolation")
struct ClaudeTeamsPolicyIsolationTests {
    @Test("Treats equals-style tmux as prompt boundary")
    func treatsEqualsStyleTmuxAsPromptBoundary() {
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
            ]
        )
    }

    @Test("Treats split tmux as prompt boundary")
    func treatsSplitTmuxAsPromptBoundary() {
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
