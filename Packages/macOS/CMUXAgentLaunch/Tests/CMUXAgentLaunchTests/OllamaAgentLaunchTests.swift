import CMUXAgentLaunch
import Testing

@Suite("Ollama launch restoration")
struct OllamaAgentLaunchTests {
    @Test("Sanitization preserves the model and safe interactive flags")
    func sanitizerPreservesInteractiveRun() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            [
                "/opt/homebrew/bin/ollama",
                "run",
                "qwen3:8b",
                "--keepalive", "10m",
                "--think", "high",
                "--verbose",
            ],
            launcher: "",
            fallbackKind: "ollama"
        ) == [
            "/opt/homebrew/bin/ollama",
            "run",
            "qwen3:8b",
            "--keepalive", "10m",
            "--think", "high",
            "--verbose",
        ])
    }

    @Test("Sanitization drops a one-shot prompt instead of replaying it")
    func sanitizerDropsPromptPayload() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "llama3.2", "explain my repository", "--verbose"],
            launcher: "",
            fallbackKind: "ollama"
        ) == ["ollama", "run", "llama3.2"])
    }

    @Test("Non-interactive Ollama commands are not restorable")
    func sanitizerRejectsNonInteractiveCommands() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "serve"], launcher: "", fallbackKind: "ollama"
        ) == nil)
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run"], launcher: "", fallbackKind: "ollama"
        ) == nil)
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "qwen3", "--help"], launcher: "", fallbackKind: "ollama"
        ) == nil)
    }

    @Test("Invalid thinking levels cannot be mistaken for the model")
    func sanitizerRejectsInvalidThinkingLevels() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "--think", "extreme", "qwen3"],
            launcher: "",
            fallbackKind: "ollama"
        ) == nil)
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "qwen3", "--think=extreme"],
            launcher: "",
            fallbackKind: "ollama"
        ) == nil)
    }

    @Test("Relaunch argv starts a fresh conversation with the captured model")
    func relaunchArgvReusesSanitizedCommand() {
        #expect(AgentResumeArgv().builtInRelaunchKind(
            kind: "ollama",
            executablePath: "/usr/local/bin/ollama",
            arguments: ["/usr/local/bin/ollama", "run", "gemma3", "--format", "json"]
        ) == ["/usr/local/bin/ollama", "run", "gemma3", "--format", "json"])
    }
}
