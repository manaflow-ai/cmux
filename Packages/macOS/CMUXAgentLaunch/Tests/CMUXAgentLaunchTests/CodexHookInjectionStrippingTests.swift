import CMUXAgentLaunch
import Testing

@Suite("Codex cmux hook injection stripping")
struct CodexHookInjectionStrippingTests {
    private let codexExecutable = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"

    @Test("Strips realistic cmux-injected Codex hook flags")
    func stripsRealisticCmuxInjectedCodexHookFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                realisticCodexHookArgv(),
                launcher: "",
                fallbackKind: "codex"
            ) == [
                codexExecutable,
                "--dangerously-bypass-approvals-and-sandbox",
                "--model",
                "gpt-5.5",
                "-c",
                "model_reasoning_effort=xhigh",
            ]
        )
    }

    @Test("Strips inline cmux Codex hook snippets")
    func stripsInlineCmuxCodexHookSnippets() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    codexExecutable,
                    "--enable",
                    "hooks",
                    "-c",
                    "hooks.SessionStart=[{hooks=[{type=\"command\",command='''tmp=$(mktemp -t cmux-codex-hook.XXXXXX); sh -c 'echo ok' cmux-codex-hook''',timeout=10000}]}]",
                    "--model",
                    "gpt-5.5",
                ],
                launcher: "",
                fallbackKind: "codex"
            ) == [codexExecutable, "--model", "gpt-5.5"]
        )
    }

    @Test("Strips joined cmux Codex hook options")
    func stripsJoinedCmuxCodexHookOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    codexExecutable,
                    "--enable=hooks",
                    "--dangerously-bypass-hook-trust",
                    "-c=hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-session-start.sh''',timeout=10000}]}]",
                    "--config",
                    "hooks.SessionStop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-session-stop.sh''',timeout=10000}]}]",
                    "--config=hooks.Notification=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-notification.sh''',timeout=10000}]}]",
                    "--model",
                    "gpt-5.5",
                ],
                launcher: "",
                fallbackKind: "codex"
            ) == [codexExecutable, "--model", "gpt-5.5"]
        )
    }

    @Test("Preserves user Codex hook config without cmux marker")
    func preservesUserCodexHookConfigWithoutCmuxMarker() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    codexExecutable,
                    "--enable",
                    "hooks",
                    "-c",
                    "hooks.SessionStart=[{hooks=[{type=\"command\",command='my-hook.sh'}]}]",
                    "--model",
                    "gpt-5.5",
                ],
                launcher: "",
                fallbackKind: "codex"
            ) == [
                codexExecutable,
                "--enable",
                "hooks",
                "-c",
                "hooks.SessionStart=[{hooks=[{type=\"command\",command='my-hook.sh'}]}]",
                "--model",
                "gpt-5.5",
            ]
        )
    }

    @Test("Codex resume preservation shares cmux hook stripping")
    func codexResumePreservationSharesCmuxHookStripping() throws {
        let resume = try #require(AgentResumeArgv().builtInKind(
            kind: "codex",
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            executablePath: codexExecutable,
            arguments: realisticCodexHookArgv()
        ))
        #expect(!resume.contains("--dangerously-bypass-hook-trust"))
        #expect(!resume.contains("--enable"))
        #expect(!resume.contains("hooks"))
        #expect(!resume.contains { $0.contains("cmux-codex-hook") })
        #expect(resume.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(resume.contains("gpt-5.5"))
        #expect(resume.contains("model_reasoning_effort=xhigh"))
    }

    @Test("Claude cmux hook settings still sanitize")
    func claudeCmuxHookSettingsStillSanitize() {
        let hookSettings = #"{"env":{"USER_FLAG":"1"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"hooks claude session-start"}]}]},"preferredNotifChannel":"notifications_disabled"}"#
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/u/.local/bin/claude",
                    "--settings",
                    hookSettings,
                    "--dangerously-skip-permissions",
                    "--model",
                    "claude-fable-5",
                    "--effort",
                    "high",
                ],
                launcher: "",
                fallbackKind: "claude"
            ) == [
                "/Users/u/.local/bin/claude",
                "--settings",
                #"{"env":{"USER_FLAG":"1"}}"#,
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5",
                "--effort",
                "high",
            ]
        )
    }


    private func realisticCodexHookArgv() -> [String] {
        [
            codexExecutable,
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-session-start.sh''',timeout=10000}]}]",
            "-c",
            "hooks.UserPromptSubmit=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-user-prompt-submit.sh''',timeout=10000}]}]",
            "-c",
            "hooks.PreToolUse=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-pre-tool-use.sh''',timeout=10000}]}]",
            "-c",
            "hooks.PostToolUse=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-post-tool-use.sh''',timeout=10000}]}]",
            "-c",
            "hooks.Notification=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-notification.sh''',timeout=10000}]}]",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]",
            "--dangerously-bypass-approvals-and-sandbox",
            "--model",
            "gpt-5.5",
            "-c",
            "model_reasoning_effort=xhigh",
        ]
    }
}
