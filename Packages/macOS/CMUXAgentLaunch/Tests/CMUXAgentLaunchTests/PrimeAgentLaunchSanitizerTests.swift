import CMUXAgentLaunch
import Testing

@Suite("Prime Agent launch sanitizer")
struct PrimeAgentLaunchSanitizerTests {
    @Test("Preserves interactive configuration and removes session selectors")
    func preservesInteractiveConfiguration() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "prime-agent",
                    "--model",
                    "prime-model",
                    "--provider",
                    "prime-provider",
                    "--thinking",
                    "high",
                    "--no-tools",
                    "--continue",
                    "--fork",
                    "/tmp/old-session.jsonl",
                    "--resume",
                    "/tmp/other-session.jsonl",
                    "--api-key",
                    "secret-must-not-persist",
                    "initial prompt must not replay",
                ],
                launcher: "prime-agent",
                fallbackKind: "prime-agent"
            ) == [
                "prime-agent",
                "--model",
                "prime-model",
                "--provider",
                "prime-provider",
                "--thinking",
                "high",
                "--no-tools",
            ]
        )
    }

    @Test("Drops short resume and continue aliases")
    func dropsShortSessionAliases() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "prime-agent",
                    "-r",
                    "/tmp/old-session.jsonl",
                    "-c",
                    "--model",
                    "prime-model",
                ],
                launcher: "prime-agent",
                fallbackKind: "prime-agent"
            ) == ["prime-agent", "--model", "prime-model"]
        )
    }

    @Test("Rejects non-interactive Prime modes")
    func rejectsNonInteractiveModes() {
        for option in ["--mode", "--daemon-socket", "--print", "--export", "--autonomous", "--goal"] {
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    ["prime-agent", option, "value"],
                    launcher: "prime-agent",
                    fallbackKind: "prime-agent"
                ) == nil
            )
        }
    }

    @Test("Rejects Prime subcommands")
    func rejectsSubcommands() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["prime-agent", "session", "list"],
                launcher: "prime-agent",
                fallbackKind: "prime-agent"
            ) == nil
        )
    }
}
