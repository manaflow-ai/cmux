import CMUXAgentLaunch
import Testing

@Suite("Codex fork sanitizer")
struct CodexForkSanitizerTests {
    @Test("Preserves direct Codex fork launch context")
    func preservesDirectCodexForkLaunchContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--model",
                    "gpt-5.4",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--sandbox",
                    "danger-full-access",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "tag-one",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--model",
                "gpt-5.4",
                "fork",
                "019dad34-d218-7943-b81a-eddac5c87951",
                "--sandbox",
                "danger-full-access",
                "tag-one",
            ]
        )
    }

    @Test("Detects Codex fork after startup image options")
    func detectsCodexForkAfterStartupImageOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "--image",
                    "/tmp/screenshot.png",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--sandbox",
                    "danger-full-access",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "tag-one",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "fork",
                "019dad34-d218-7943-b81a-eddac5c87951",
                "--sandbox",
                "danger-full-access",
                "tag-one",
            ]
        )
    }

    @Test("Preserves generated Codex fork launch context")
    func preservesGeneratedCodexForkLaunchContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "fork",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    "/tmp/extra repo",
                    "--sandbox",
                    "danger-full-access",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == [
                "codex",
                "fork",
                "019dad34-d218-7943-b81a-eddac5c87951",
                "--model",
                "gpt-5.4",
                "--add-dir",
                "/tmp/extra repo",
                "--sandbox",
                "danger-full-access",
            ]
        )
    }

    @Test("Preserves Codex Teams fork launch context")
    func preservesCodexTeamsForkLaunchContext() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--ask-for-approval",
                    "never",
                    "--remote",
                    "ws://127.0.0.1:1",
                    "--remote-auth-token-env=OLD_CODEX_TOKEN",
                    "tag-one",
                ],
                launcher: "codexTeams",
                fallbackKind: "codex"
            ) == [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "codex-teams",
                "--model",
                "gpt-5.4",
                "fork",
                "019dad34-d218-7943-b81a-eddac5c87951",
                "--ask-for-approval",
                "never",
                "tag-one",
            ]
        )
    }

    @Test("Hook capture preserves fork prompt tags for replay")
    func hookCapturePreservesForkPromptTagsForReplay() throws {
        let capturedArguments = try #require(capturedForkLaunchArguments())

        #expect(
            capturedArguments == [
                "codex",
                "fork",
                "019ef275-74e3-7777-9773-9dcb118ed5ad",
                "tag-one",
                "--sandbox",
                "danger-full-access",
            ]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: capturedArguments
            ) == ["/opt/bin/codex", "fork", "CHILD", "tag-one", "--sandbox", "danger-full-access"]
        )
    }

    @Test("Resume drops captured fork prompt tags but preserves later options")
    func resumeDropsCapturedForkPromptTagsButPreservesLaterOptions() throws {
        let capturedArguments = try #require(capturedForkLaunchArguments())

        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: capturedArguments
            ) == ["/opt/bin/codex", "resume", "CHILD", "--sandbox", "danger-full-access"]
        )
    }

    private func capturedForkLaunchArguments() -> [String]? {
        AgentLaunchSanitizer.sanitizedLaunchArguments(
            [
                "codex",
                "fork",
                "019ef275-74e3-7777-9773-9dcb118ed5ad",
                "tag-one",
                "--sandbox",
                "danger-full-access",
            ],
            launcher: "codex",
            fallbackKind: "codex"
        )
    }
}
