import CMUXAgentLaunch
import Testing

@Suite("Kimi agent resume")
struct KimiAgentResumeTests {
    @Test("Builds Kimi's documented session-id resume argv")
    func buildsSessionResumeArgv() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "kimi",
                sessionId: "72124c21-7b09-40a1-a98f-718164c46431",
                executablePath: nil,
                arguments: ["kimi"]
            ) == ["kimi", "--resume", "72124c21-7b09-40a1-a98f-718164c46431"]
        )
    }

    @Test("Drops stale Kimi session selectors and prompt modes while preserving interactive configuration")
    func sanitizesCapturedLaunchArguments() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/example/.local/bin/kimi",
                    "--session", "old-session",
                    "--model", "kimi-k2",
                    "--thinking",
                    "--add-dir", "/tmp/extra repo",
                    "--config-file", "/tmp/kimi config.toml",
                    "initial prompt should not replay",
                ],
                launcher: "kimi",
                fallbackKind: "kimi"
            ) == [
                "/Users/example/.local/bin/kimi",
                "--model", "kimi-k2",
                "--thinking",
                "--add-dir", "/tmp/extra repo",
                "--config-file", "/tmp/kimi config.toml",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["kimi", "--continue", "--model", "kimi-k2"],
                launcher: "kimi",
                fallbackKind: "kimi"
            ) == ["kimi", "--model", "kimi-k2"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["kimi", "--print", "--prompt", "one shot"],
                launcher: "kimi",
                fallbackKind: "kimi"
            ) == nil
        )
    }

    @Test("Kimi lookup stays in its launch directory and custom share directory")
    func preservesSessionNamespace() {
        #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: "kimi") == .byDirectory)
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "kimi",
                runtimeCwd: "/Users/example/repo/worktree",
                launchWorkingDirectory: "/Users/example/repo"
            ) == "/Users/example/repo"
        )
        #expect(
            AgentLaunchEnvironmentPolicy().selectedEnvironment(
                from: [
                    "KIMI_SHARE_DIR": "/Users/example/.local/share/kimi-custom",
                    "MOONSHOT_API_KEY": "secret",
                ],
                kind: "kimi"
            ) == ["KIMI_SHARE_DIR": "/Users/example/.local/share/kimi-custom"]
        )
    }
}
