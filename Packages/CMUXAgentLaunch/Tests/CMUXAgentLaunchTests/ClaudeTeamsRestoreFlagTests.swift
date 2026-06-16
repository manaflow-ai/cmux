import CMUXAgentLaunch
import Testing

@Suite("Claude Teams restore flags")
struct ClaudeTeamsRestoreFlagTests {
    @Test("Preserves tmux mode and common session flags")
    func preservesTmuxAndCommonSessionFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--teammate-mode",
                    "auto",
                    "--tmux",
                    "--chrome",
                    "--ide",
                    "--dangerously-skip-permissions",
                    "--allow-dangerously-skip-permissions",
                    "--bare",
                    "--safe-mode",
                    "--strict-mcp-config",
                    "--prompt-suggestions",
                    "false",
                    "--remote-control",
                    "team",
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
                "--chrome",
                "--ide",
                "--dangerously-skip-permissions",
                "--allow-dangerously-skip-permissions",
                "--bare",
                "--safe-mode",
                "--strict-mcp-config",
                "--prompt-suggestions",
                "false",
                "--remote-control",
                "team",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Preserves optional Claude flags without swallowing the next flag")
    func preservesOptionalFlagsWithoutSwallowingNextFlag() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--remote-control",
                    "--no-chrome",
                    "--prompt-suggestions",
                    "--model",
                    "sonnet",
                    "initial prompt should not replay",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--remote-control",
                "--no-chrome",
                "--prompt-suggestions",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Infers one value for future long options before another flag")
    func infersFutureLongOptionValueBeforeAnotherFlag() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--future-mode",
                    "enabled",
                    "--chrome",
                    "initial prompt should not replay",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--future-mode",
                "enabled",
                "--chrome",
            ]
        )
    }

    @Test("Does not infer unknown option values at the prompt boundary")
    func doesNotInferUnknownOptionValueAtPromptBoundary() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--future-boolean",
                    "initial prompt should not replay",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--future-boolean",
            ]
        )
    }
}
