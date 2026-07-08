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

    @Test("Keeps user hook enabling flags when cmux injection is stripped")
    func keepsUserHookEnablingFlagsWhenCmuxInjectionIsStripped() {
        // cmux splices exactly one `--enable hooks` + one trust flag alongside
        // its marker configs; the user's own enable flag and hook config after
        // them must survive stripping so the preserved hook stays enabled.
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    codexExecutable,
                    "--enable",
                    "hooks",
                    "--dangerously-bypass-hook-trust",
                    "-c",
                    "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]",
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

    @Test("Unwraps node-hosted known agent argv")
    func unwrapsNodeHostedKnownAgentArgv() {
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex", cmuxCodexHookMarker, "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == ["codex", cmuxCodexHookMarker, "--model", "gpt-5.5"]
        )
    }

    @Test("Unwrap skips node options before script")
    func unwrapSkipsNodeOptionsBeforeScript() {
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                [
                    "node",
                    "--require",
                    "tsx",
                    "--import=loader",
                    "--conditions",
                    "development",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/claude.js",
                    cmuxClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == ["claude", cmuxClaudeHookSettingsMarker, "--model", "claude-fable-5"]
        )
    }

    @Test("Unwrap bails when node option consumes script")
    func unwrapBailsWhenNodeOptionConsumesScript() {
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "-e", "require('/tools/codex')", cmuxCodexHookMarker, "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "--eval", "require('/tools/codex')", cmuxCodexHookMarker],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
    }

    @Test("Unwrap derives the agent name from the cmux marker for package entrypoints")
    func unwrapDerivesAgentNameFromCmuxMarkerForPackageEntrypoints() {
        // Claude Code's real npm entrypoint is cli.js — the basename never
        // matches an agent name, so the injected-marker identity is used when
        // the script lives inside that agent's own npm package directory.
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                [
                    "node",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    cmuxClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == ["claude", cmuxClaudeHookSettingsMarker, "--model", "claude-fable-5"]
        )
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/dist/cli.js", cmuxCodexHookMarker, "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == ["codex", cmuxCodexHookMarker, "--model", "gpt-5.5"]
        )
        // Hook-looking argv contents on a script outside the agent's package
        // must never rewrite it into an agent command.
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "script.js", cmuxCodexHookMarker, "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "/tools/router.js", cmuxClaudeHookSettingsMarker, "--model", "claude-fable-5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
    }

    @Test("Unwrap accepts bun-hosted known agents")
    func unwrapAcceptsBunHostedKnownAgents() {
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["bun", "/Users/u/.bun/install/global/node_modules/@openai/codex/bin/codex.mjs", cmuxCodexHookMarker, "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == ["codex", cmuxCodexHookMarker, "--model", "gpt-5.5"]
        )
    }

    @Test("Unwrap requires cmux wrapper-injected hook arguments")
    func unwrapRequiresCmuxWrapperInjectedHookArguments() {
        // Without the cmux wrapper's injected hook marker there is no proof
        // the user launched the agent by bare name through the PATH shim, so
        // a script named like an agent — even a package-manager install
        // launched directly or a project-local pinned version — must never be
        // rewritten into whatever the bare name resolves to.
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "/tools/claude.js", "--model", "claude-fable-5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "./codex.js", "--foo"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["node", "/repo/node_modules/@openai/codex/bin/codex", "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
        #expect(
            AgentLaunchSanitizer.unwrappedJavaScriptRuntimeAgentArgv(
                ["bun", "/repo/bin/codex.mjs", "--model", "gpt-5.5"],
                isKnownAgentExecutableName: isKnownAgentExecutableName
            ) == nil
        )
    }

    @Test("Wrapper marker detection identifies injected argv")
    func wrapperMarkerDetectionIdentifiesInjectedArgv() {
        #expect(AgentLaunchSanitizer.containsCmuxWrapperInjectedHookArguments(realisticCodexHookArgv()))
        #expect(AgentLaunchSanitizer.containsCmuxWrapperInjectedHookArguments([
            "/Users/u/.local/bin/claude", cmuxClaudeHookSettingsMarker,
        ]))
        #expect(!AgentLaunchSanitizer.containsCmuxWrapperInjectedHookArguments([
            codexExecutable, "--model", "gpt-5.5",
        ]))
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

    private func isKnownAgentExecutableName(_ name: String) -> Bool {
        name == "codex" || name == "claude"
    }

    /// A cmux-wrapper-injected codex hook config in joined `-c=` form: the
    /// launch-time marker proving the PATH shim wrapper spawned the process.
    private let cmuxCodexHookMarker =
        "-c=hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]"

    /// A cmux-wrapper-injected claude hook settings payload in joined
    /// `--settings=` form.
    private let cmuxClaudeHookSettingsMarker =
        #"--settings={"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"hooks claude session-start"}]}]}}"#
}
