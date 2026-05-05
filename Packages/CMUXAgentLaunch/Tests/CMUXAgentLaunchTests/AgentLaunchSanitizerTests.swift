import CMUXAgentLaunch
import Testing

@Suite("AgentLaunchSanitizer")
struct AgentLaunchSanitizerTests {
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

    @Test("Drops pi --session/--continue/--no-session before preserving later options")
    func dropsPiSessionSelectorsBeforePreservingLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi",
                    "--continue",
                    "--session",
                    "old-session",
                    "--no-session",
                    "--provider",
                    "anthropic",
                    "--model",
                    "claude-sonnet-4-5",
                    "--thinking",
                    "medium"
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == [
                "pi",
                "--provider",
                "anthropic",
                "--model",
                "claude-sonnet-4-5",
                "--thinking",
                "medium"
            ]
        )
    }

    @Test("Drops pi positional prompt and stops parsing")
    func dropsPiPositionalPromptAndStopsParsing() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi",
                    "--model",
                    "claude-sonnet-4-5",
                    "refactor this codebase",
                    "--provider",
                    "anthropic"
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == [
                "pi",
                "--model",
                "claude-sonnet-4-5"
            ]
        )
    }

    @Test("pi install/update/list subcommands are non-restorable")
    func piNonRestorableSubcommandsReturnNil() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "install", "./my-extension"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "update"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["pi", "list"],
                launcher: "pi",
                fallbackKind: "pi"
            ) == nil
        )
    }
}
