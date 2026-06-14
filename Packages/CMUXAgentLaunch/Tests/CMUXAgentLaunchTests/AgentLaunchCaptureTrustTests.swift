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

    func testSubrouterWrapperLaunchersDescribeEveryKind() {
        // The team launches every agent through the `sr` subrouter wrapper
        // (`sr claude`, `sr codex`, `sr opencode`, `sr pi`), exported as the
        // captured launcher. `sr` is a symlink to `~/bin/subrouter`, so the
        // resolved binary name `subrouter` can appear too. Both are generic
        // wrappers that can front ANY kind and must be trusted for all of them,
        // exactly like the cmux-owned `claudeTeams`/`codexTeams`/`omo` wrappers.
        // Regression: https://github.com/manaflow-ai/cmux/pull/5937 omitted them,
        // distrusting every sr-launched session and hiding Fork Conversation.
        for kind in ["claude", "codex", "opencode", "pi"] {
            XCTAssertTrue(
                AgentLaunchCaptureTrust.launcherDescribesKind("sr", kind: kind),
                "sr should describe \(kind)"
            )
            XCTAssertTrue(
                AgentLaunchCaptureTrust.launcherDescribesKind("subrouter", kind: kind),
                "subrouter should describe \(kind)"
            )
        }
        // Launcher matching is case-insensitive (the launcher is lowercased).
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("SR", kind: "claude"))
        XCTAssertTrue(AgentLaunchCaptureTrust.launcherDescribesKind("Subrouter", kind: "codex"))
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
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/usr/local/bin/codex", "--yolo"]))
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper([]))
        // An agent that merely shares a shell's basename must stay trusted.
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["/Users/alice/.local/bin/fish", "--resume", "x"]))
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["sh"]))
        // `--chrome` is a long option, not a shell command-string flag.
        XCTAssertFalse(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(["zsh", "--chrome"]))
    }
}
