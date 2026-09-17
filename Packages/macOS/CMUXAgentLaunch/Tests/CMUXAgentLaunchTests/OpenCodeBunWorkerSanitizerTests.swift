import CMUXAgentLaunch
import Testing

@Suite("OpenCode Bun worker sanitizer")
struct OpenCodeBunWorkerSanitizerTests {
    @Test("Drops internal TUI worker paths", arguments: [
        "/$bunfs/root/src/cli/cmd/tui/worker.js",
        "/$bunfs/root/src/cli/tui/worker.js",
    ])
    func dropsInternalTUIWorkerPaths(workerPath: String) {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/lawrence/.bun/bin/opencode",
                    workerPath,
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--session",
                    "old-session",
                    "--port",
                    "4096",
                    "/Users/lawrence/fun",
                ],
                launcher: "opencode",
                fallbackKind: "opencode"
            ) == [
                "/Users/lawrence/.bun/bin/opencode",
                "--model",
                "anthropic/claude-sonnet-4-6",
                "--port",
                "4096",
                "/Users/lawrence/fun",
            ]
        )
    }
}
