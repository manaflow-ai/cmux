import Testing
@testable import CMUXAgentLaunch

// Keep the existing table-driven call sites compact while exercising the
// constructable production classifier on every assertion.
extension AgentLaunchModeClassifier {
    static func processMode(
        processName: String?,
        arguments: [String]?,
        kind: String
    ) -> AgentProcessLaunchMode {
        AgentLaunchModeClassifier().processMode(
            processName: processName,
            arguments: arguments,
            kind: kind
        )
    }
}

@Suite("Agent launch capture trust")
struct AgentLaunchCaptureTrustTests {
    @Test func exactKindMatchIsTrusted() {
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("codex", kind: "codex"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("Claude", kind: "claude"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("pi", kind: "pi"))
    }

    @Test func absentLauncherIsTrusted() {
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind(nil, kind: "codex"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("  ", kind: "codex"))
    }

    @Test func absentLauncherUsesHookKindToValidateCapture() {
        #expect(
            AgentLaunchCaptureTrust.capturedArgumentsDescribeKind(
                launcher: nil,
                executablePath: "/opt/homebrew/bin/codex",
                arguments: ["/opt/homebrew/bin/codex", "--yolo"],
                kind: "codex"
            )
        )
    }

    @Test func customInterpreterEntrypointDescribesKindButKeepsUnknownMode() {
        let arguments = ["/usr/local/bin/node", "/opt/local-agent/bin/local-agent.js", "resume"]
        #expect(AgentLaunchCaptureTrust.nativeProcessDescribesKind(
            processName: "node",
            arguments: arguments,
            kind: "local-agent"
        ))
        #expect(AgentLaunchModeClassifier.processMode(
            processName: "node",
            arguments: arguments,
            kind: "local-agent"
        ) == .unknown)
    }

    @Test func nativeKindInferencePrefersExactKindsAndUniqueAliases() {
        #expect(AgentLaunchCaptureTrust.nativeAgentKind(
            processName: "/opt/bin/claude",
            arguments: ["/opt/bin/claude", "--print", "fix this"]
        ) == "claude")
        #expect(AgentLaunchCaptureTrust.nativeAgentKind(
            processName: "/usr/bin/node",
            arguments: [
                "/usr/bin/node",
                "/opt/node_modules/@anthropic-ai/claude-code/cli.js",
                "--print",
            ]
        ) == "claude")
        #expect(AgentLaunchCaptureTrust.nativeAgentKind(
            processName: "/opt/bin/omp",
            arguments: ["/opt/bin/omp", "--print", "fix this"]
        ) == "omp")
        #expect(AgentLaunchCaptureTrust.nativeAgentKind(
            processName: "/opt/bin/droid",
            arguments: ["/opt/bin/droid"]
        ) == "factory")
        #expect(AgentLaunchCaptureTrust.nativeAgentKind(
            processName: "/opt/bin/future-agent",
            arguments: ["/opt/bin/future-agent", "codex", "exec"]
        ) == nil)
        #expect(AgentLaunchCaptureTrust.nativeAgentKind(
            processName: "/opt/bin/claude",
            arguments: ["/opt/bin/codex"]
        ) == nil)
    }

    @Test func wrapperLaunchersDescribeTheirKind() {
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("claudeTeams", kind: "claude"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("codexTeams", kind: "codex"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("omo", kind: "opencode"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("omx", kind: "opencode"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("omc", kind: "opencode"))
        #expect(AgentLaunchCaptureTrust.launcherDescribesKind("omp", kind: "pi"))
    }

    @Test func crossAgentLauncherIsDistrusted() {
        #expect(!AgentLaunchCaptureTrust.launcherDescribesKind("claude", kind: "codex"))
        #expect(!AgentLaunchCaptureTrust.launcherDescribesKind("codex", kind: "claude"))
        #expect(!AgentLaunchCaptureTrust.launcherDescribesKind("claudeTeams", kind: "codex"))
        #expect(!AgentLaunchCaptureTrust.launcherDescribesKind("omo", kind: "codex"))
    }

    @Test func shellWrapperArgvDetection() {
        #expect(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["sh", "-c", "eval x"]))
        #expect(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/bin/zsh", "-lc", "codex"]))
        #expect(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/bin/zsh", "-lic", "codex"]))
        #expect(!AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/usr/local/bin/codex", "--yolo"]))
        #expect(!AgentLaunchCaptureTrust.argvLooksLikeShellWrapper([]))
        // An agent that merely shares a shell's basename must stay trusted.
        #expect(!AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/Users/alice/.local/bin/fish", "--resume", "x"]))
        #expect(!AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["sh"]))
        // `--chrome` is a long option, not a shell command-string flag.
        #expect(!AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["zsh", "--chrome"]))
    }

    @Test func pidProcessMetadataMustMatchHookKind() {
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--sandbox", "workspace-write"],
                kind: "codex"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--sandbox", "workspace-write"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: ["node", "/Users/alice/.claude/local/claude.js"],
                kind: "claude"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "grok-macos-aarch64",
                arguments: ["/Users/alice/.local/bin/grok-macos-aarch64", "-r", "session"],
                kind: "grok"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "kiro-cli",
                arguments: ["/Users/alice/.cargo/bin/kiro-cli", "chat"],
                kind: "kiro"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "campfire",
                arguments: ["/Users/alice/.local/bin/campfire", "--session", "session"],
                kind: "campfire"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "campfire",
                arguments: ["/Users/alice/.local/bin/campfire", "--session", "session"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "hermes",
                arguments: ["/Users/alice/.local/bin/hermes", "chat"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "bun",
                arguments: ["bun", "/Users/alice/campfire/packages/session/bin/campfire.ts"],
                kind: "campfire"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "node",
                arguments: ["node", "/Users/alice/campfire/packages/session/dist/campfire"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "tsx",
                arguments: ["tsx", "packages/session/bin/campfire.ts"],
                kind: "campfire"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "deno",
                arguments: ["deno", "run", "-A", "/Users/alice/campfire/packages/session/bin/campfire.ts"],
                kind: "campfire"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "ts-node",
                arguments: ["ts-node", "/Users/alice/campfire/packages/session/bin/campfire.ts"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "node",
                arguments: ["node", "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.js"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "bun",
                arguments: ["bun", "/Users/alice/.bun/install/global/node_modules/opencode-ai/bin/cli.js"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessIsAmbiguousInterpreterHost(
                processName: "deno",
                arguments: ["deno", "run", "/Users/alice/future-agent/src/cli.ts"]
            )
        )
        #expect(
            !AgentLaunchCaptureTrust.nativeProcessIsAmbiguousInterpreterHost(
                processName: "node",
                arguments: ["node", "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.js"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "acme-agent",
                arguments: ["/Users/alice/bin/acme-agent", "--session", "native-session"],
                kind: "acme-agent"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "cmux DEV",
                arguments: [
                    "/tmp/cmux-tests/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
                    "-NSTreatUnknownArgumentsAsOpen",
                ],
                kind: "codex"
            ) == false
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex"],
                kind: "claude"
            ) == false
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "agy",
                arguments: ["/usr/local/bin/agy"],
                kind: "antigravity"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "kimi",
                arguments: ["/Users/alice/.local/bin/kimi"],
                kind: "kimi"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "kimi",
                arguments: ["/Users/alice/.local/bin/kimi"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "kimi-cli",
                arguments: ["/Users/alice/.local/bin/kimi-cli"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "kimi-code",
                arguments: ["/Users/alice/.local/bin/kimi-code"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "github-copilot-cli",
                arguments: ["/Users/alice/.local/bin/github-copilot-cli"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "opencode-ai",
                arguments: ["/Users/alice/.local/bin/opencode-ai"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "open-code",
                arguments: ["/Users/alice/.local/bin/open-code"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "amp",
                arguments: ["/Users/alice/.local/bin/amp"]
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "acli",
                arguments: ["/Users/alice/.local/bin/acli", "rovodev"]
            )
        )
    }

    @Test func thinSameAgentLaunchersAreNotSessionAncestors() {
        #expect(
            AgentLaunchCaptureTrust.nativeProcessIsSameAgentLauncherRelay(
                parentProcessName: "node",
                parentArguments: ["node", "/Users/alice/.bun/bin/codex"],
                childProcessName: "codex",
                childArguments: ["/Users/alice/.bun/lib/node_modules/@openai/codex/vendor/codex", "--yolo"],
                kind: "codex"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessIsSameAgentLauncherRelay(
                parentProcessName: "node",
                parentArguments: [
                    "node",
                    "/Users/alice/.bun/bin/gemini",
                    "--yolo",
                    "--model",
                    "gemini-3.1-pro-preview",
                ],
                childProcessName: "node",
                childArguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                    "/Users/alice/.bun/bin/gemini",
                    "--yolo",
                    "--model",
                    "gemini-3.1-pro-preview",
                ],
                kind: "gemini"
            )
        )
        #expect(
            !AgentLaunchCaptureTrust.nativeProcessIsSameAgentLauncherRelay(
                parentProcessName: "node",
                parentArguments: [
                    "node",
                    "--use-system-ca",
                    "/Users/alice/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    "--model", "sonnet",
                ],
                childProcessName: "claude",
                childArguments: [
                    "/Users/alice/.local/share/claude/versions/2.1.214",
                    "--model", "sonnet",
                ],
                kind: "claude"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessIsSameAgentLauncherRelay(
                parentProcessName: "node",
                parentArguments: [
                    "node", "--use-system-ca", "/Users/alice/.bun/bin/codex",
                    "--yolo",
                ],
                childProcessName: "codex",
                childArguments: [
                    "/Users/alice/.bun/lib/node_modules/@openai/codex/vendor/codex",
                    "--yolo",
                ],
                kind: "codex"
            )
        )
        #expect(
            !AgentLaunchCaptureTrust.nativeProcessIsSameAgentLauncherRelay(
                parentProcessName: "codex",
                parentArguments: ["/Users/alice/.local/bin/codex", "--yolo"],
                childProcessName: "codex",
                childArguments: ["/Users/alice/.local/bin/codex", "resume", "child-session"],
                kind: "codex"
            )
        )
    }

    @Test func exactLauncherRejectsTruncatedInterpreterCapture() {
        #expect(
            !AgentLaunchCaptureTrust.capturedArgumentsDescribeKind(
                launcher: "gemini",
                executablePath: "/Users/alice/.hermes/node/bin/node",
                arguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                ],
                kind: "gemini"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.capturedArgumentsDescribeKind(
                launcher: "gemini",
                executablePath: "/Users/alice/.hermes/node/bin/node",
                arguments: [
                    "/Users/alice/.hermes/node/bin/node",
                    "--max-old-space-size=65536",
                    "/Users/alice/.bun/bin/gemini",
                ],
                kind: "gemini"
            )
        )
    }

    @Test func interpreterTrustUsesOnlyTheActualScriptEntrypoint() {
        let misleadingArguments = [
            "node",
            "/tmp/unrelated-tool.js",
            "/tmp/codex",
            "--print",
        ]
        #expect(
            !AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: misleadingArguments,
                kind: "codex"
            )
        )
        #expect(
            !AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "node",
                arguments: misleadingArguments
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: misleadingArguments,
                kind: "codex"
            ) == nil
        )

        let trustedArguments = [
            "node",
            "--use-system-ca",
            "/Users/alice/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "--print",
            "fix this",
        ]
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: trustedArguments,
                kind: "claude"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: trustedArguments,
                kind: "claude"
            ) == ["--print", "fix this"]
        )

        let preloadedArguments = [
            "node",
            "--require", "/tmp/codex.js",
            "/Users/alice/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "--print",
        ]
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: preloadedArguments,
                kind: "claude"
            )
        )
        #expect(
            !AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: preloadedArguments,
                kind: "codex"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeAgentLaunchArguments(
                processName: "node",
                arguments: preloadedArguments,
                kind: "claude"
            ) == ["--print"]
        )
    }

    @Test func liveProcessModeSeparatesOneShotInteractiveAndUnknownLaunches() {
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "exec", "fix this"],
                kind: "codex"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--model", "o3"],
                kind: "codex"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: ["opencode", "run", "--interactive", "fix this"],
                kind: "opencode"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--future-launch-mode"],
                kind: "codex"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "sleep",
                arguments: ["/bin/sleep", "30"],
                kind: "codex"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acme-agent",
                arguments: ["/usr/local/bin/acme-agent", "--print", "fix this"],
                kind: "acme-agent"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: ["opencode", "pr", "123"],
                kind: "opencode"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude",
                arguments: ["claude", "--background", "fix this"],
                kind: "claude"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "hermes",
                arguments: ["hermes", "-q", "fix this"],
                kind: "hermes-agent"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "hermes",
                arguments: ["hermes", "chat", "-q", "fix this"],
                kind: "hermes-agent"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kimi",
                arguments: ["kimi", "--quiet", "fix this"],
                kind: "kimi"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "pi",
                arguments: ["pi", "--no-session"],
                kind: "pi"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kimi",
                arguments: ["kimi", "--prompt", "fix this"],
                kind: "kimi"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kiro-cli",
                arguments: ["kiro-cli", "chat", "--no-interactive", "fix this"],
                kind: "kiro"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kiro-cli",
                arguments: ["kiro-cli", "doctor", "--no-interactive"],
                kind: "kiro"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acli",
                arguments: ["acli", "rovodev", "run"],
                kind: "rovodev"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acli",
                arguments: ["acli", "rovodev", "run", "fix this"],
                kind: "rovodev"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acli",
                arguments: ["acli", "rovodev", "run", "--prompt-interactive", "fix this"],
                kind: "rovodev"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acli",
                arguments: ["acli", "rovodev", "config"],
                kind: "rovodev"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "droid",
                arguments: [
                    "droid", "exec",
                    "--input-format", "stream-jsonrpc",
                    "--output-format", "stream-jsonrpc",
                ],
                kind: "factory"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "codex",
                arguments: ["codex", "--future-launch-mode", "exec", "fix this"],
                kind: "codex"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude",
                arguments: ["claude", "--background", "--print", "fix this"],
                kind: "claude"
            ) == .unknown
        )
    }

    @Test func codexUtilityCommandsAreNonSessionAndNeverRestorable() {
        let utilityCommands = [
            "plugin",
            "remote-control",
            "archive",
            "delete",
            "unarchive",
            "update",
            "doctor",
        ]

        for command in utilityCommands {
            let arguments = ["codex", command]
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "codex",
                    arguments: arguments,
                    kind: "codex"
                ) == .nonSession,
                "codex \(command)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments,
                    launcher: "codex",
                    fallbackKind: "codex"
                ) == nil,
                "codex \(command)"
            )
        }

        for command in ["app-server", "mcp-server", "exec-server"] {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "codex",
                    arguments: ["codex", command],
                    kind: "codex"
                ) == .interactive,
                "codex \(command)"
            )
        }
    }

    @Test func grokUtilityCommandsAreNonSessionAndNeverRestorable() {
        for command in [
            "completions",
            "dashboard",
            "export",
            "logout",
            "plugin",
            "wrap",
        ] {
            let arguments = ["grok", command]
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: "grok",
                    arguments: arguments,
                    kind: "grok"
                ) == .nonSession,
                "grok \(command)"
            )
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    arguments,
                    launcher: "grok",
                    fallbackKind: "grok"
                ) == nil,
                "grok \(command)"
            )
        }
    }

    @Test func commonOneShotFlagsDoNotHideTerminalLaunches() {
        let oneShotLaunches: [(kind: String, executable: String, arguments: [String])] = [
            ("kimi", "kimi", ["--print", "fix this", "--yolo"]),
            ("gemini", "gemini", ["-p", "fix this", "--yolo"]),
            ("grok", "grok", ["--single", "fix this", "--always-approve"]),
            ("pi", "pi", ["-p", "fix this", "--verbose"]),
            ("cursor", "cursor-agent", ["-p", "fix this", "--auto-review"]),
            ("amp", "amp", ["-x", "fix this", "--no-archive-after-execute"]),
            ("amp", "amp", ["-x", "fix this", "--plugin-ready-timeout", "30"]),
        ]
        for launch in oneShotLaunches {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: launch.executable,
                    arguments: [launch.executable] + launch.arguments,
                    kind: launch.kind
                ) == .oneShot,
                "\(launch.kind) \(launch.arguments)"
            )
        }

        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "pi",
                arguments: ["pi", "-p", "fix this", "--future-output-mode"],
                kind: "pi"
            ) == .unknown
        )
    }

    @Test func openCodeRunUsesRunOptionContractsInBothModes() {
        let runValues = [
            "--format", "json",
            "--command", "build",
            "--share",
            "--pure",
        ]
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: ["opencode", "run", "fix this"] + runValues,
                kind: "opencode"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: ["opencode", "run", "--interactive", "fix this"] + runValues,
                kind: "opencode"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: ["opencode", "run", "fix this", "--future-run-mode"],
                kind: "opencode"
            ) == .unknown
        )
    }

    @Test func interpreterHostedLaunchRestorabilityStartsAfterTheAgentEntrypoint() {
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "node",
                arguments: [
                    "node",
                    "--use-system-ca",
                    "/Users/alice/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    "--print",
                    "fix this",
                ],
                kind: "claude"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "bun",
                arguments: [
                    "bun",
                    "/Users/alice/.bun/install/global/node_modules/opencode-ai/bin/cli.js",
                    "run",
                    "fix this",
                ],
                kind: "opencode"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "deno",
                arguments: [
                    "deno",
                    "run",
                    "-A",
                    "/Users/alice/campfire/packages/session/bin/campfire.ts",
                    "--print",
                    "fix this",
                ],
                kind: "campfire"
            ) == .oneShot
        )
    }

    @Test func longLivedProtocolModesOverrideOneShotLookingArguments() {
        let launches: [(kind: String, executable: String, arguments: [String])] = [
            ("claude", "claude", ["--print", "--input-format", "stream-json", "--output-format", "stream-json"]),
            ("pi", "pi", ["--mode", "rpc", "--print", "fix this"]),
            ("omp", "omp", ["--mode=rpc-ui", "--print", "fix this"]),
            ("omp", "omp", ["acp", "--print", "fix this"]),
            ("campfire", "campfire", ["--mode", "rpc", "--print", "fix this"]),
            ("kimi", "kimi", ["--acp", "--print", "fix this"]),
            ("kimi", "kimi", ["acp"]),
            ("hermes-agent", "hermes", ["acp", "--oneshot", "fix this"]),
            ("hermes-agent", "hermes", ["gateway", "run"]),
            ("grok", "grok", ["agent", "stdio", "--single", "fix this"]),
            ("grok", "grok", ["agent", "serve"]),
            ("grok", "grok", ["agent", "leader"]),
            ("opencode", "opencode", ["acp"]),
            ("opencode", "opencode", ["serve"]),
            ("opencode", "opencode", ["web"]),
            ("qoder", "qodercli", ["--acp", "--print", "fix this"]),
            ("qoder", "qodercli", ["--input-format", "stream-json", "--print", "fix this"]),
            ("codex", "codex", ["app-server"]),
            ("codex", "codex", ["mcp-server"]),
            ("codex", "codex", ["exec-server"]),
        ]

        for launch in launches {
            #expect(
                AgentLaunchModeClassifier.processMode(
                    processName: launch.executable,
                    arguments: [launch.executable] + launch.arguments,
                    kind: launch.kind
                ) != .oneShot,
                "\(launch.kind) \(launch.arguments) was classified as terminal"
            )
        }
    }

    @Test func commandContractsFailClosedAroundUnknownOptionsAndPromptBoundaries() {
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "codex",
                arguments: ["codex", "exec", "--future-output", "fix this"],
                kind: "codex"
            ) == .oneShot
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: ["opencode", "run", "--future-protocol", "fix this"],
                kind: "opencode"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "droid",
                arguments: ["droid", "exec", "--future-protocol", "fix this"],
                kind: "factory"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude",
                arguments: ["claude", "--", "--print"],
                kind: "claude"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "kiro-cli",
                arguments: ["kiro-cli", "chat", "--", "--no-interactive"],
                kind: "kiro"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude",
                arguments: ["claude", "--print", "--input-format=stream-json"],
                kind: "claude"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "pi",
                arguments: ["pi", "--print", "--mode=rpc"],
                kind: "pi"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "droid",
                arguments: [
                    "droid", "exec",
                    "--input-format=stream-jsonrpc",
                    "--output-format=stream-jsonrpc",
                ],
                kind: "factory"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "opencode",
                arguments: [
                    "opencode", "run", "fix this",
                    "--interactive", "--future-launch-mode",
                ],
                kind: "opencode"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "claude",
                arguments: [
                    "claude", "--input-format", "stream-json",
                    "--future-protocol-option",
                ],
                kind: "claude"
            ) == .interactive
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acli",
                arguments: [
                    "acli", "rovodev", "run",
                    "--prompt-interactive", "fix this",
                    "--future-launch-mode",
                ],
                kind: "rovodev"
            ) == .unknown
        )
        #expect(
            AgentLaunchModeClassifier.processMode(
                processName: "acli",
                arguments: [
                    "acli", "rovodev", "run",
                    "--prompt-interactive", "fix this",
                    "--prompt", "one shot",
                ],
                kind: "rovodev"
            ) == .unknown
        )
    }
}
