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
                    "--worktree",
                    "feature",
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
                "--worktree",
                "feature",
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

    @Test("Does not preserve one-token prompts after tmux")
    func doesNotPreserveOneTokenPromptAfterTmux() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "fix",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
            ]
        )
    }

    @Test("Treats prompt tokens after tmux as terminal")
    func treatsPromptTokensAfterTmuxAsTerminal() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--permission-mode",
                    "auto",
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

    @Test("Skips dash-leading prompt text after tmux")
    func skipsDashLeadingPromptTextAfterTmux() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "--dangerously-skip-permissions investigate this",
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

    @Test("Preserves permission flags after tmux before a prompt")
    func preservesPermissionFlagsAfterTmuxBeforePrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "--dangerously-skip-permissions",
                    "fix bug",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--tmux",
                "--dangerously-skip-permissions",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "--permission-mode",
                    "auto",
                    "fix bug",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--tmux",
                "--permission-mode",
                "auto",
            ]
        )
    }

    @Test("Preserves tmux boundary after bare worktree")
    func preservesTmuxBoundaryAfterBareWorktree() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--worktree",
                    "--tmux",
                    "fix",
                    "--permission-mode",
                    "auto",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--worktree",
                "--permission-mode",
                "auto",
            ]
        )
    }

    @Test("Preserves terminal values for other Claude optional flags")
    func preservesTerminalValuesForOtherClaudeOptionalFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--remote-control",
                    "team",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--remote-control",
                "team",
            ]
        )
    }

    @Test("Preserves named remote control before later flags")
    func preservesNamedRemoteControlBeforeLaterFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--remote-control",
                    "my-phone",
                    "--model",
                    "sonnet",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--remote-control",
                "my-phone",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Preserves optional Claude values before a prompt")
    func preservesOptionalClaudeValuesBeforePrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--remote-control",
                    "team",
                    "fix bug",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--remote-control",
                "team",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--prompt-suggestions",
                    "false",
                    "fix bug",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--prompt-suggestions",
                "false",
            ]
        )
    }

    @Test("Does not consume one-token prompts as optional Claude values")
    func doesNotConsumeOneTokenPromptsAsOptionalClaudeValues() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--prompt-suggestions",
                    "fix",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--prompt-suggestions",
            ]
        )
    }

    @Test("Preserves future equals-style long option values")
    func preservesFutureEqualsStyleLongOptionValues() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--future-mode=enabled",
                    "--chrome",
                    "initial prompt should not replay",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--future-mode=enabled",
                "--chrome",
            ]
        )
    }

    @Test("Does not infer ambiguous future option values before another flag")
    func doesNotInferAmbiguousFutureOptionValueBeforeAnotherFlag() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--future-boolean",
                    "fix",
                    "--model",
                    "sonnet",
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
