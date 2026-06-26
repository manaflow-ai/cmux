import XCTest
@testable import CMUXAgentLaunch

final class AgentLaunchCaptureTrustTests: XCTestCase {
    func testExactKindMatchIsTrusted() {
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("codex", kind: "codex"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("Claude", kind: "claude"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("pi", kind: "pi"))
    }

    func testAbsentLauncherIsTrusted() {
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind(nil, kind: "codex"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("  ", kind: "codex"))
    }

    func testWrapperLaunchersDescribeTheirKind() {
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("claudeTeams", kind: "claude"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("codexTeams", kind: "codex"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("omo", kind: "opencode"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("omx", kind: "opencode"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("omc", kind: "opencode"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("omp", kind: "pi"))
    }

    func testCrossAgentLauncherIsDistrusted() {
        XCTAssertFalse(AgentLaunchCaptureTrust.launcherDescribesKind("claude", kind: "codex"))
        XCTAssertFalse(AgentLaunchCaptureTrust.launcherDescribesKind("codex", kind: "claude"))
        XCTAssertFalse(AgentLaunchCaptureTrust.launcherDescribesKind("claudeTeams", kind: "codex"))
        XCTAssertFalse(AgentLaunchCaptureTrust.launcherDescribesKind("omo", kind: "codex"))
    }

    func testShellWrapperArgvDetection() {
        XCTAssertTrue(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["sh", "-c", "eval x"]))
        XCTAssertTrue(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/bin/zsh", "-lc", "codex"]))
        XCTAssertTrue(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/bin/zsh", "-lic", "codex"]))
        XCTAssertTrue(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["bash", "--noprofile", "--norc", "-c", "claude"]))
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/usr/local/bin/codex", "--yolo"]))
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper([]))
        // An agent that merely shares a shell's basename must stay trusted.
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/Users/alice/.local/bin/fish", "--resume", "x"]))
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["sh"]))
        // `--chrome` is a long option, not a shell command-string flag.
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["zsh", "--chrome"]))
        // A script may accept its own `-c`; after the script operand, it is not a shell flag.
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["zsh", "/path/to/agent-wrapper", "-c", "config"]))
    }

    func testPIDProcessMetadataMustMatchHookKind() {
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--sandbox", "workspace-write"],
                kind: "codex"
            )
        )
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex", "--sandbox", "workspace-write"]
            )
        )
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "node",
                arguments: ["node", "/Users/alice/.claude/local/claude.js"],
                kind: "claude"
            )
        )
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "grok-macos-aarch64",
                arguments: ["/Users/alice/.local/bin/grok-macos-aarch64", "-r", "session"],
                kind: "grok"
            )
        )
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "kiro-cli",
                arguments: ["/Users/alice/.cargo/bin/kiro-cli", "chat"],
                kind: "kiro"
            )
        )
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "acme-agent",
                arguments: ["/Users/alice/bin/acme-agent", "--session", "native-session"],
                kind: "acme-agent"
            )
        )
        XCTAssertFalse(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "cmux DEV",
                arguments: [
                    "/tmp/cmux-tests/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
                    "-NSTreatUnknownArgumentsAsOpen",
                ],
                kind: "codex"
            )
        )
        XCTAssertFalse(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "codex",
                arguments: ["/opt/homebrew/bin/codex"],
                kind: "claude"
            )
        )
        XCTAssertTrue(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "agy",
                arguments: ["/usr/local/bin/agy"],
                kind: "antigravity"
            )
        )
    }
}
