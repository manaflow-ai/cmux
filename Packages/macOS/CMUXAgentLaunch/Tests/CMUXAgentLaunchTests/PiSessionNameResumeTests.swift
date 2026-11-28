import CMUXAgentLaunch
import Testing

@Suite("Pi session name resume")
struct PiSessionNameResumeTests {
    @Test("Preserves a Pi session name through capture and resume", arguments: ["--name", "-n"], ["review", "Review login changes"])
    func preservesSessionName(option: String, name: String) throws {
        let captured = try #require(AgentLaunchSanitizer.sanitizedLaunchArguments(
            [
                "pi", option, name, "--session", "old-session",
                "--model", "example-model", "--api-key", "secret",
                "initial prompt", "--name", "prompt text"
            ],
            launcher: "pi",
            fallbackKind: "pi"
        ))
        #expect(captured == ["pi", option, name, "--model", "example-model"])
        #expect(AgentResumeArgv().builtInKind(
            kind: "pi",
            sessionId: "restored-session",
            executablePath: nil,
            arguments: captured
        ) == ["pi", "--session", "restored-session", option, name, "--model", "example-model"])
    }

    @Test("Does not infer values for unknown Pi flags")
    func unknownFlagDoesNotCapturePrompt() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["pi", "--unknown-flag", "private prompt", "--name", "prompt text"],
            launcher: "pi",
            fallbackKind: "pi"
        ) == ["pi", "--unknown-flag"])
    }

    @Test("Campfire still drops joiner names", arguments: ["--name", "--join-as"])
    func campfireDropsJoinerName(option: String) {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["campfire", option, "Guest name", "--model", "example-model"],
            launcher: "campfire",
            fallbackKind: "campfire"
        ) == ["campfire", "--model", "example-model"])
    }
}
