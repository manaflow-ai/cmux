import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchSanitizer")
struct AgentLaunchSanitizerTests {
    @Test("Preserves Codex Teams launcher while dropping prompt")
    func preservesCodexTeamsLauncher() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "--ask-for-approval",
                    "never",
                    "initial prompt should not replay",
                ],
                launcher: "codexTeams",
                fallbackKind: "codex"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "codex-teams",
                "--model",
                "gpt-5.4",
                "--sandbox",
                "danger-full-access",
                "--ask-for-approval",
                "never",
            ]
        )
    }

    @Test("Consumes terminal optional values")
    func consumesTerminalOptionalValues() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["copilot", "--model", "gpt-5.4", "--allow-tool", "Read"],
                launcher: "copilot",
                fallbackKind: "copilot"
            ) == ["copilot", "--model", "gpt-5.4", "--allow-tool", "Read"]
        )
    }

    @Test("Drops Gemini worktree value before preserving later options")
    func dropsGeminiWorktreeValueBeforePreservingLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["gemini", "--worktree", "/tmp/repo", "--model", "gemini-2.5-pro"],
                launcher: "gemini",
                fallbackKind: "gemini"
            ) == ["gemini", "--model", "gemini-2.5-pro"]
        )
    }

    @Test("Preserves Cursor options after resume subcommand")
    func preservesCursorOptionsAfterResumeSubcommand() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["cursor-agent", "resume", "chat-123", "--model", "gpt-5.4", "--sandbox", "enabled"],
                launcher: "cursor",
                fallbackKind: "cursor"
            ) == ["cursor-agent", "--model", "gpt-5.4", "--sandbox", "enabled"]
        )
    }

    @Test("Drops Pi session selectors and prompt while preserving configuration")
    func dropsPiSessionSelectorsAndPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi", "--session", "old-session", "--model", "anthropic/claude-sonnet-4-5",
                    "--thinking", "high", "--api-key", "secret", "implement this",
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == ["pi", "--model", "anthropic/claude-sonnet-4-5", "--thinking", "high"]
        )
    }

    @Test("Preserves repeated Pi extension and skill flags without replaying prompt")
    func preservesRepeatedPiExtensionAndSkillFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi", "--extension", "a.ts", "--extension", "b.ts",
                    "--skill", "review", "--skill", "swift", "initial prompt",
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == [
                "pi", "--extension", "a.ts", "--extension", "b.ts",
                "--skill", "review", "--skill", "swift",
            ]
        )
    }

    @Test("Rejects noninteractive Pi launches")
    func rejectsNoninteractivePiLaunches() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "--print", "summarize"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "--prompt", "summarize"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
    }

    @Test("Preserves Hermes inherited flags without replaying startup-only input")
    func preservesHermesInheritedFlagsWithoutReplayingStartupOnlyInput() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "hermes",
                    "--profile",
                    "work",
                    "--tui",
                    "--skills",
                    "github-auth",
                    "-s",
                    "hermes-agent-dev",
                    "--api-key",
                    "secret",
                    "--image",
                    "/tmp/cat.png",
                    "--worktree",
                    "--resume",
                    "old-session",
                    "--source",
                    "cli",
                    "initial prompt should not replay",
                ],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == [
                "hermes",
                "--profile",
                "work",
                "--tui",
                "--skills",
                "github-auth",
                "-s",
                "hermes-agent-dev",
            ]
        )
    }

    @Test("Drops Hermes worktree value before preserving later options")
    func dropsHermesWorktreeValueBeforePreservingLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--worktree", "/tmp/repo", "--model", "anthropic/claude-sonnet-4.6"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--model", "anthropic/claude-sonnet-4.6"]
        )
    }

    @Test("Allows only Hermes chat or default session launch")
    func allowsOnlyHermesChatOrDefaultSessionLaunch() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "chat", "--tui", "--model", "anthropic/claude-sonnet-4.6", "initial prompt"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--tui", "--model", "anthropic/claude-sonnet-4.6"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "fallback", "list"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "slack", "send"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == nil
        )
    }

    @Test("Treats Hermes skills as single value options")
    func treatsHermesSkillsAsSingleValueOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["hermes", "--skills", "skill1", "skill2", "--model", "anthropic/claude-sonnet-4.6"],
                launcher: "hermes-agent",
                fallbackKind: "hermes-agent"
            ) == ["hermes", "--skills", "skill1"]
        )
    }

    @Test("Drops Amp --label and its value while preserving later options")
    func dropsAmpLabelValueAndPreservesLaterOptions() {
        // --label takes a value. If --label isn't in valueOptions, the
        // sanitizer drops only `--label` and `foo` slips through as a
        // positional, breaking the resumed launch.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "--label", "foo", "--mode", "geppetto"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--mode", "geppetto"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "-l", "bar", "--effort", "high"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--effort", "high"]
        )
    }

    @Test("Rejects non-restorable Amp launches and strips resume preamble")
    func rejectsNonRestorableAmpLaunchesAndStripsResumePreamble() {
        // --execute / --print / -x are non-interactive runs; not restorable.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "--execute", "do this", "--mode", "geppetto"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == nil
        )
        // A previously-resumed launch should have its `threads continue <id>`
        // preamble stripped so a re-resume doesn't re-prepend it.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["amp", "threads", "continue", "T-old-id", "--mode", "geppetto"],
                launcher: "amp",
                fallbackKind: "amp"
            ) == ["amp", "--mode", "geppetto"]
        )
    }
}
