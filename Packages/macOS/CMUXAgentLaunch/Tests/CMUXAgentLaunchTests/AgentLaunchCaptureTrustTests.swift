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
    }
}
