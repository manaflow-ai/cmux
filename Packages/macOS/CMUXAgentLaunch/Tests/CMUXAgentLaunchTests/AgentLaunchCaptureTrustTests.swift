import Testing
@testable import CMUXAgentLaunch

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
}
