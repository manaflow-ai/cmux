import CMUXAgentLaunch
import Testing

@Suite("Claude Teams prompt boundary recovery")
struct ClaudeTeamsPromptBoundaryRecoveryTests {
    @Test("Recovers restore-safe flags after tmux payload for remote-control launches")
    func recoversRestoreSafeFlagsAfterTmuxPayloadForRemoteControlLaunches() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--remote-control-session-name-prefix",
                    "cmux-team",
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
                "--remote-control-session-name-prefix",
                "cmux-team",
                "--permission-mode",
                "auto",
            ]
        )
    }

    @Test("Recovers restore-safe flags at end of argv")
    func recoversRestoreSafeFlagsAtEndOfArgv() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--remote-control-session-name-prefix",
                    "cmux-team",
                    "--tmux",
                    "side effect should be dropped",
                    "--model",
                    "sonnet",
                    "--permission-mode",
                    "auto",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--remote-control-session-name-prefix",
                "cmux-team",
                "--model",
                "sonnet",
                "--permission-mode",
                "auto",
            ]
        )
    }
}
