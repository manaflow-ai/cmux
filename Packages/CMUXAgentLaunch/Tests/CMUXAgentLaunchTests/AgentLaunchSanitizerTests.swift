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
                    "initial prompt should not replay"
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
                "hermes-agent-dev"
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
}
