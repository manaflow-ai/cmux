import CMUXAgentLaunch
import Testing

@Suite("Claude resume flag preservation")
struct ClaudeResumeFlagPreservationTests {
    @Test("Preserves flags after prompt positional")
    func preservesFlagsAfterPromptPositional() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "investigate the flaky test",
                    "--dangerously-skip-permissions",
                    "--model",
                    "claude-fable-5",
                    "--effort",
                    "max"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5",
                "--effort",
                "max"
            ]
        )
    }

    @Test("Preserves unknown value option and later known options")
    func preservesUnknownValueOptionAndLaterKnownOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--some-new-flag",
                    "value",
                    "--dangerously-skip-permissions",
                    "--model",
                    "claude-fable-5"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--some-new-flag",
                "value",
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5"
            ]
        )
    }

    @Test("Preserves all development channel values")
    func preservesAllDevelopmentChannelValues() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--dangerously-load-development-channels",
                    "chan-a",
                    "chan-b",
                    "--dangerously-skip-permissions"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-load-development-channels",
                "chan-a",
                "chan-b",
                "--dangerously-skip-permissions"
            ]
        )
    }

    @Test("Preserves flags before prompt positional")
    func preservesFlagsBeforePromptPositional() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--model",
                    "claude-fable-5",
                    "--dangerously-skip-permissions",
                    "do the thing"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "claude-fable-5",
                "--dangerously-skip-permissions"
            ]
        )
    }

    @Test("Drops session binding flags while later flags survive")
    func dropsSessionBindingFlagsWhileLaterFlagsSurvive() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--resume",
                    "0195aaaa-bbbb-cccc-dddd-eeeeffff0000",
                    "--dangerously-skip-permissions",
                    "prompt here",
                    "--model",
                    "opus"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-skip-permissions",
                "--model",
                "opus"
            ]
        )
    }

    @Test("Does not replay trailing prompt after unknown boolean flag")
    func doesNotReplayTrailingPromptAfterUnknownBooleanFlag() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--dangerously-skip-permissions",
                    "investigate"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-skip-permissions"
            ]
        )
    }

    @Test("Stops variadic development channels at prompt-shaped token")
    func stopsVariadicDevelopmentChannelsAtPromptShapedToken() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--dangerously-load-development-channels",
                    "dev",
                    "fix the flaky test",
                    "--model",
                    "opus"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--dangerously-load-development-channels",
                "dev",
                "--model",
                "opus"
            ]
        )
    }

    @Test("Rejects non-restorable Claude subcommand")
    func rejectsNonRestorableClaudeSubcommand() {
        #expect(
            AgentLaunchSanitizer.preservedArguments(
                kind: "claude",
                args: ["doctor", "--model", "opus"]
            ) == nil
        )
    }

    @Test("Stops scanning at double dash")
    func stopsScanningAtDoubleDash() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--model",
                    "opus",
                    "--",
                    "--dangerously-skip-permissions"
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "opus"
            ]
        )
    }

    @Test("Codex still stops scanning at prompt positional")
    func codexStillStopsScanningAtPromptPositional() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--model",
                    "gpt-5",
                    "investigate",
                    "--sandbox",
                    "danger-full-access"
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--model",
                "gpt-5"
            ]
        )
    }
}
