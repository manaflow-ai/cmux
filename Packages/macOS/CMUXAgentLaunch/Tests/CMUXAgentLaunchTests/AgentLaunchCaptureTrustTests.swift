import Testing
@testable import CMUXAgentLaunch

@Suite
struct AgentLaunchCaptureTrustTests {
    private let trust = AgentLaunchCaptureTrust()

    @Test func exactKindMatchIsTrusted() {
        #expect(trust.launcherDescribesKind("codex", kind: "codex"))
        #expect(trust.launcherDescribesKind("Claude", kind: "claude"))
        #expect(trust.launcherDescribesKind("pi", kind: "pi"))
    }

    @Test func absentLauncherIsTrusted() {
        #expect(trust.launcherDescribesKind(nil, kind: "codex"))
        #expect(trust.launcherDescribesKind("  ", kind: "codex"))
    }

    @Test func wrapperLaunchersDescribeTheirKind() {
        #expect(trust.launcherDescribesKind("claudeTeams", kind: "claude"))
        #expect(trust.launcherDescribesKind("codexTeams", kind: "codex"))
        #expect(trust.launcherDescribesKind("omo", kind: "opencode"))
        #expect(trust.launcherDescribesKind("omx", kind: "opencode"))
        #expect(trust.launcherDescribesKind("omc", kind: "opencode"))
        #expect(trust.launcherDescribesKind("omp", kind: "pi"))
    }

    @Test func crossAgentLauncherIsDistrusted() {
        #expect(!trust.launcherDescribesKind("claude", kind: "codex"))
        #expect(!trust.launcherDescribesKind("codex", kind: "claude"))
        #expect(!trust.launcherDescribesKind("claudeTeams", kind: "codex"))
        #expect(!trust.launcherDescribesKind("omo", kind: "codex"))
    }

    @Test func shellWrapperArgvDetection() {
        #expect(trust.argvLooksLikeShellWrapper(["sh", "-c", "eval x"]))
        #expect(trust.argvLooksLikeShellWrapper(["/bin/zsh", "-lc", "codex"]))
        #expect(trust.argvLooksLikeShellWrapper(["/bin/zsh", "-lic", "codex"]))
        #expect(trust.argvLooksLikeShellWrapper(["bash", "--noprofile", "--norc", "-c", "claude"]))
        #expect(trust.argvLooksLikeShellWrapper(["bash", "--noprofile", "--norc"]))
        #expect(!trust.argvLooksLikeShellWrapper(["/usr/local/bin/codex", "--yolo"]))
        #expect(!trust.argvLooksLikeShellWrapper([]))
        #expect(!trust.argvLooksLikeShellWrapper(["/Users/alice/.local/bin/fish", "--resume", "x"]))
        #expect(!trust.argvLooksLikeShellWrapper(["sh"]))
        #expect(!trust.argvLooksLikeShellWrapper(["zsh", "--chrome"]))
        #expect(!trust.argvLooksLikeShellWrapper(["zsh", "/path/to/agent-wrapper", "-c", "config"]))
    }

    @Test func pidProcessMetadataMustMatchHookKind() {
        #expect(
            trust.nativeProcessDescribesKind(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--sandbox", "workspace-write"],
                kind: "codex"
            )
        )
        #expect(
            trust.nativeProcessDescribesKnownAgent(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--sandbox", "workspace-write"]
            )
        )
        #expect(
            trust.nativeProcessDescribesKind(
                processName: "node",
                arguments: ["node", "/Users/alice/.claude/local/claude.js"],
                kind: "claude"
            )
        )
        #expect(
            trust.nativeProcessDescribesKind(
                processName: "grok-macos-aarch64",
                arguments: ["/Users/alice/.local/bin/grok-macos-aarch64", "-r", "session"],
                kind: "grok"
            )
        )
        #expect(
            trust.nativeProcessDescribesKind(
                processName: "kiro-cli",
                arguments: ["/Users/alice/.cargo/bin/kiro-cli", "chat"],
                kind: "kiro"
            )
        )
        #expect(
            trust.nativeProcessDescribesKind(
                processName: "acme-agent",
                arguments: ["/Users/alice/bin/acme-agent", "--session", "native-session"],
                kind: "acme-agent"
            )
        )
        #expect(
            !trust.nativeProcessDescribesKind(
                processName: "cmux DEV",
                arguments: [
                    "/tmp/cmux-tests/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
                    "-NSTreatUnknownArgumentsAsOpen",
                ],
                kind: "codex"
            )
        )
        #expect(
            !trust.nativeProcessDescribesKind(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex"],
                kind: "claude"
            )
        )
        #expect(
            trust.nativeProcessDescribesKind(
                processName: "agy",
                arguments: ["/usr/local/bin/agy"],
                kind: "antigravity"
            )
        )
    }
}
