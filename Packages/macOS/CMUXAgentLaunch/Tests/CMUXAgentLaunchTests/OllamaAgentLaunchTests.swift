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
                "--think=high",
                "--verbose",
            ],
            launcher: "",
            fallbackKind: "ollama"
        ) == [
            "/opt/homebrew/bin/ollama",
            "run",
            "qwen3:8b",
            "--keepalive", "10m",
            "--think=high",
            "--verbose",
        ])
    }

    @Test("A one-shot prompt makes the command non-restorable")
    func sanitizerRejectsOneShotPrompt() {
        // Restoring would launch an interactive REPL the user never started.
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "llama3.2", "explain my repository", "--verbose"],
            launcher: "",
            fallbackKind: "ollama"
        ) == nil)
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

    @Test("Invalid explicit thinking levels are not restorable")
    func sanitizerRejectsInvalidThinkingLevels() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "qwen3", "--think=extreme"],
            launcher: "",
            fallbackKind: "ollama"
        ) == nil)
    }

    @Test("Bare --think never consumes the next token")
    func sanitizerTreatsBareThinkAsValueless() {
        // Upstream registers --think with an optional value (NoOptDefVal),
        // so "high" here is Ollama's one-shot prompt, not a level, which
        // makes the whole command non-restorable.
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "qwen3", "--think", "high", "--verbose"],
            launcher: "",
            fallbackKind: "ollama"
        ) == nil)
        // Before the model, the token after a bare --think is the model.
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "--think", "qwen3"],
            launcher: "",
            fallbackKind: "ollama"
        ) == ["ollama", "run", "--think", "qwen3"])
    }

    @Test("Sanitization preserves the explicit maximum thinking level")
    func sanitizerPreservesMaximumThinkingLevel() {
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["ollama", "run", "qwen3", "--think=max"],
            launcher: "",
            fallbackKind: "ollama"
        ) == ["ollama", "run", "qwen3", "--think=max"])
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
