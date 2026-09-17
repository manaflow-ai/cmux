import CMUXAgentLaunch
import Testing

@Suite("Claude Teams restore flags")
struct ClaudeTeamsRestoreFlagTests {
    @Test("Preserves common session flags before tmux prompt boundary")
    func preservesCommonSessionFlagsBeforeTmuxPromptBoundary() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--teammate-mode",
                    "auto",
                    "--worktree",
                    "feature",
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
                    "--tmux",
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

    @Test("Drops restore-looking prompt text after tmux payload")
    func dropsRestoreLookingPromptTextAfterTmuxPayload() {
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
            ]
        )
    }

    @Test("Drops option-looking prompt text after tmux")
    func dropsOptionLookingPromptTextAfterTmux() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "explain",
                    "--dangerously-skip-permissions",
                    "and continue",
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
                    "explain",
                    "why",
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

    @Test("Stops tmux recovery at end-of-options delimiter")
    func stopsTmuxRecoveryAtEndOfOptionsDelimiter() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--",
                    "--permission-mode",
                    "auto",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
            ]
        )
    }

    @Test("Stops tmux recovery when safe value option is incomplete")
    func stopsTmuxRecoveryWhenSafeValueOptionIsIncomplete() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--model",
                    "--permission-mode",
                    "auto",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
            ]
        )
    }

    @Test("Preserves permission flags before tmux prompt boundary")
    func preservesPermissionFlagsBeforeTmuxPromptBoundary() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--dangerously-skip-permissions",
                    "--tmux",
                    "fix bug",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--dangerously-skip-permissions",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--permission-mode",
                    "auto",
                    "--tmux",
                    "fix bug",
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
