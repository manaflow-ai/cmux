import CMUXAgentLaunch
import Testing

@Suite("Codex cmux hook injection stripping")
struct CodexHookInjectionStrippingTests {
    private let codexExecutable = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"

    @Test("Strips realistic cmux-injected Codex hook flags")
    func stripsRealisticCmuxInjectedCodexHookFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["codex"] + realisticCodexHookArgv().dropFirst(),
                launcher: "",
                fallbackKind: "codex"
            ) == [
                "codex",
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
                    "codex",
                    "--enable",
                    "hooks",
                    "-c",
                    "hooks.SessionStart=[{hooks=[{type=\"command\",command='''payload=$(mktemp -t cmux-codex-hook.XXXXXX); sh -c 'echo ok' cmux-codex-hook \"$payload\" \"$cmux_cli\" hooks codex session-start''',timeout=10000}]}]",
                    "--model",
                    "gpt-5.5",
                ],
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips joined cmux Codex hook options")
    func stripsJoinedCmuxCodexHookOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
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
            ) == ["codex", "--model", "gpt-5.5"]
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
                    "codex",
                    "--enable",
                    "hooks",
                    "--dangerously-bypass-hook-trust",
                    "-c",
                    "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]",
                    "--enable",
                    "hooks",
                    "-c",
                    "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/cmux-codex-hook-wrapper.sh'''}]}]",
                    "--model",
                    "gpt-5.5",
                ],
                launcher: "",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--enable",
                "hooks",
                "-c",
                "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/cmux-codex-hook-wrapper.sh'''}]}]",
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
                    "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/cmux-codex-hook-wrapper.sh'''}]}]",
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
                "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/cmux-codex-hook-wrapper.sh'''}]}]",
                "--model",
                "gpt-5.5",
            ]
        )
    }

    @Test("Codex resume preservation keeps hooks with captured executable")
    func codexResumePreservationKeepsHooksWithCapturedExecutable() throws {
        let resume = try #require(AgentResumeArgv().builtInKind(
            kind: "codex",
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            executablePath: codexExecutable,
            arguments: realisticCodexHookArgv()
        ))
        #expect(resume.contains("--dangerously-bypass-hook-trust"))
        #expect(resume.contains("--enable"))
        #expect(resume.contains("hooks"))
        #expect(resume.contains { $0.contains("cmux-codex-hook") })
        #expect(resume.first == codexExecutable)
        #expect(resume.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(resume.contains("gpt-5.5"))
        #expect(resume.contains("model_reasoning_effort=xhigh"))
    }

    @Test("Codex fork preservation keeps hooks with captured executable")
    func codexForkPreservationKeepsHooksWithCapturedExecutable() throws {
        let fork = try #require(AgentForkArgv().builtInKind(
            kind: "codex",
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            executablePath: codexExecutable,
            arguments: realisticCodexHookArgv()
        ))
        #expect(fork.contains("--dangerously-bypass-hook-trust"))
        #expect(fork.contains { $0.contains("cmux-codex-hook") })
        #expect(fork.first == codexExecutable)
    }

    @Test("Claude cmux hook settings preserve captured executable")
    func claudeCmuxHookSettingsPreserveCapturedExecutable() {
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
                hookSettings,
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5",
                "--effort",
                "high",
            ]
        )
    }

    @Test("Unwrap preserves node-hosted Codex without identity proof")
    func unwrapPreservesNodeHostedCodexWithoutIdentityProof() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + cmuxCodexHookArgs + ["resume", "019dad34-d218-7943-b81a-eddac5c87951", "--model", "gpt-5.5"]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
        )
    }

    @Test("Unwrap skips node options before script")
    func unwrapSkipsNodeOptionsBeforeScript() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
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
                ]
            ) == [
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
            ]
        )
    }

    @Test("Unwrap bails when node option consumes script")
    func unwrapBailsWhenNodeOptionConsumesScript() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "-e", "require('/tools/codex')"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "--eval", "require('/tools/codex')"] + cmuxCodexHookArgs
            ) == nil
        )
    }

    @Test("Unwrap preserves Claude package entrypoints without identity proof")
    func unwrapPreservesClaudePackageEntrypointsWithoutIdentityProof() {
        // Claude Code's real npm entrypoint is cli.js — the basename never
        // matches an agent name, so the package path identifies the sanitizer
        // policy while preserving the captured runtime and script path.
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                [
                    "node",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    cmuxClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ]
            ) == ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", cmuxClaudeHookSettingsMarker, "--model", "claude-fable-5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                [
                    "node",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    "--session-id",
                    "4e06e114-61b2-48ed-93cd-561a23eb5216",
                    cmuxClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ]
            ) == [
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                cmuxClaudeHookSettingsMarker,
                "--model",
                "claude-fable-5",
            ]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/dist/cli.js"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/dist/cli.js"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex", cmuxClaudeHookSettingsMarker]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex", cmuxClaudeHookSettingsMarker]
        )
        // Hook-looking argv contents on a script outside the agent's package
        // must never rewrite it into an agent command.
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "script.js"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/tools/router.js", cmuxClaudeHookSettingsMarker, "--model", "claude-fable-5"]
            ) == nil
        )
    }

    @Test("Unwrap preserves bun-hosted Codex without identity proof")
    func unwrapPreservesBunHostedCodexWithoutIdentityProof() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["bun", "/Users/u/.bun/install/global/node_modules/@openai/codex/bin/codex.mjs"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
            ) == ["bun", "/Users/u/.bun/install/global/node_modules/@openai/codex/bin/codex.mjs"] + cmuxCodexHookArgs + ["--model", "gpt-5.5"]
        )
    }

    @Test("Unwrap does not rewrite project-local scripts")
    func unwrapDoesNotRewriteProjectLocalScripts() {
        // A script named like an agent must never be rewritten into whatever
        // the bare name resolves to. Known package-manager entrypoints can be
        // sanitized while preserving their captured runtime and script path.
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/tools/claude.js", "--model", "claude-fable-5"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "./codex.js", "--foo"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/repo/node_modules/@openai/codex/bin/codex", "--model", "gpt-5.5"]
            ) == ["node", "/repo/node_modules/@openai/codex/bin/codex", "--model", "gpt-5.5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["bun", "/repo/bin/codex.mjs", "--model", "gpt-5.5"]
            ) == nil
        )
    }

    @Test("Wrapper marker detection does not trust hook argv")
    func wrapperMarkerDetectionDoesNotTrustHookArgv() {
        #expect(!runtimeUnwrapper.containsCmuxWrapperInjectedHookArguments(realisticCodexHookArgv()))
        #expect(!runtimeUnwrapper.containsCmuxWrapperInjectedHookArguments([
            "/Users/u/.local/bin/claude", cmuxClaudeHookSettingsMarker,
        ]))
        #expect(!runtimeUnwrapper.containsCmuxWrapperInjectedHookArguments([
            "/Users/u/.local/bin/claude",
            "--session-id",
            "4e06e114-61b2-48ed-93cd-561a23eb5216",
            "--settings",
            cmuxClaudeHookSettingsValue,
        ]))
        #expect(!runtimeUnwrapper.containsCmuxWrapperInjectedHookArguments([
            "/opt/pinned/claude",
            "--settings",
            userOwnedClaudeHookSettingsValue,
        ]))
        #expect(
            runtimeUnwrapper.unwrappedArgv([
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "--settings",
                userOwnedClaudeHookSettingsValue,
            ]) == [
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "--settings",
                userOwnedClaudeHookSettingsValue,
            ]
        )
        #expect(!runtimeUnwrapper.containsCmuxWrapperInjectedHookArguments([
            codexExecutable,
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]",
            "--model",
            "gpt-5.5",
        ]))
        #expect(!runtimeUnwrapper.containsCmuxWrapperInjectedHookArguments([
            codexExecutable, "--model", "gpt-5.5",
        ]))
    }

    private var runtimeUnwrapper: JavaScriptRuntimeAgentLaunchUnwrapper {
        JavaScriptRuntimeAgentLaunchUnwrapper(isKnownAgentExecutableName: isKnownAgentExecutableName)
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

    /// A minimal cmux-wrapper-injected Codex hook argument prefix: the
    /// launch-time marker proving the PATH shim wrapper spawned the process.
    private let cmuxCodexHookArgs = [
        "--enable",
        "hooks",
        "--dangerously-bypass-hook-trust",
        "-c=hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.cmux/hooks/cmux-codex-hook-stop.sh''',timeout=10000}]}]",
    ]

    /// A cmux-wrapper-injected claude hook settings payload in joined
    /// `--settings=` form.
    private let cmuxClaudeHookSettingsMarker =
        #"--settings={"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude session-start","timeout":10}]}]}}"#

    /// The same cmux-wrapper-injected claude hook settings payload in split
    /// `--settings <json>` form.
    private let cmuxClaudeHookSettingsValue =
        #"{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\" hooks claude session-start","timeout":10}]}]}}"#

    /// User-owned settings may mention hook commands without proving that cmux's
    /// wrapper launched the executable.
    private let userOwnedClaudeHookSettingsValue =
        #"{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/Users/u/bin/hooks claude session-start"}]}]}}"#
}
