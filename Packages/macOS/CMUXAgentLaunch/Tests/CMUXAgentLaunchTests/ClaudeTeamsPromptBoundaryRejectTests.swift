import CMUXAgentLaunch
import Testing

@Suite("Claude Teams prompt boundary rejects")
struct ClaudeTeamsPromptBoundaryRejectTests {
    @Test("Drops non-restorable-looking prompt text after tmux prompt boundary")
    func dropsNonRestorableLookingPromptTextAfterTmuxPromptBoundary() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--no-session-persistence",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--print=true",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
            ]
        )
    }
}
