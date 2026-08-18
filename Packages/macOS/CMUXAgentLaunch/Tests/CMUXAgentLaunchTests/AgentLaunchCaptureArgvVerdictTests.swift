import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch capture argv verdict")
struct AgentLaunchCaptureArgvVerdictTests {
    @Test func trustsAnArgvThatDescribesTheKind() {
        let verdict = AgentLaunchCaptureTrust.nativeProcessArgvVerdict(
            processName: "codex",
            arguments: ["/usr/local/bin/codex", "resume", "abc"],
            kind: "codex"
        )
        #expect(verdict == .trusted(["/usr/local/bin/codex", "resume", "abc"]))
    }

    /// The hook's PID fallback landed on an unrelated process (another agent, a
    /// test host, the cmux app itself). The record must say so rather than only
    /// that it holds no argv.
    @Test func namesTheGroundWhenTheProcessDescribesAnotherAgent() {
        let verdict = AgentLaunchCaptureTrust.nativeProcessArgvVerdict(
            processName: "claude",
            arguments: ["/usr/local/bin/claude", "--resume", "abc"],
            kind: "codex"
        )
        #expect(verdict == .rejected(.nativeProcessDoesNotDescribeKind))
    }

    /// The PID resolved to the hook's own dispatch shell. The process name still
    /// describes the kind, so only the argv gives it away.
    @Test func namesTheGroundWhenTheArgvIsAShellDispatcher() {
        let verdict = AgentLaunchCaptureTrust.nativeProcessArgvVerdict(
            processName: "codex",
            arguments: ["/bin/zsh", "-lc", "codex resume abc"],
            kind: "codex"
        )
        #expect(verdict == .rejected(.argvLooksLikeShellWrapper))
    }

    @Test(arguments: [nil, []] as [[String]?])
    func namesTheGroundWhenThereIsNoArgvToJudge(arguments: [String]?) {
        let verdict = AgentLaunchCaptureTrust.nativeProcessArgvVerdict(
            processName: nil,
            arguments: arguments,
            kind: "codex"
        )
        #expect(verdict == .rejected(.argvUnavailable))
    }

    /// The verdict only names grounds; it must not widen or narrow which argv
    /// the hook was already willing to trust.
    @Test func trustDecisionMatchesTheChecksItWraps() {
        let cases: [(String?, [String])] = [
            ("codex", ["/usr/local/bin/codex"]),
            ("claude", ["/usr/local/bin/claude", "--resume"]),
            ("codex", ["/bin/sh", "-c", "codex"]),
            ("node", ["/usr/bin/node", "/home/u/.claude/versions/1.0/cli.js"]),
            (nil, ["/opt/homebrew/bin/codex", "exec", "run"]),
        ]
        for (processName, arguments) in cases {
            for kind in ["codex", "claude"] {
                let trusted = AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                    processName: processName,
                    arguments: arguments,
                    kind: kind
                ) && !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(arguments)
                let verdict = AgentLaunchCaptureTrust.nativeProcessArgvVerdict(
                    processName: processName,
                    arguments: arguments,
                    kind: kind
                )
                #expect(
                    (verdict == .trusted(arguments)) == trusted,
                    "kind=\(kind) processName=\(processName ?? "nil") argv=\(arguments)"
                )
            }
        }
    }
}
