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

    @Test("Drops Pi session selectors and prompt while preserving configuration")
    func dropsPiSessionSelectorsAndPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "pi", "--session", "old-session", "--model", "anthropic/claude-sonnet-4-5",
                    "--thinking", "high", "--api-key", "secret", "implement this"
                ],
                launcher: "pi",
                fallbackKind: "pi"
            ) == ["pi", "--model", "anthropic/claude-sonnet-4-5", "--thinking", "high"]
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
}
