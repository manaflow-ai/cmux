import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launch capture argv verdict")
struct AgentLaunchCaptureArgvVerdictTests {
    /// The ordinary case: the PID resolved to the agent the hook belongs to.
    @Test func trustsAnArgvThatDescribesTheKind() {
        let verdict = AgentLaunchCaptureArgvVerdict(
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
        let verdict = AgentLaunchCaptureArgvVerdict(
            processName: "claude",
            arguments: ["/usr/local/bin/claude", "--resume", "abc"],
            kind: "codex"
        )
        #expect(verdict == .rejected(.nativeProcessDoesNotDescribeKind))
    }

    /// The PID resolved to a shell dispatcher, typically the hook's own. The
    /// ground holds whether the process name still points at the agent or has
    /// already become the shell: a `-c` invocation is not a launch either way.
    @Test(arguments: ["codex", "zsh", nil] as [String?])
    func namesTheGroundWhenTheArgvIsAShellDispatcher(processName: String?) {
        let verdict = AgentLaunchCaptureArgvVerdict(
            processName: processName,
            arguments: ["/bin/zsh", "-lc", "codex resume abc"],
            kind: "codex"
        )
        #expect(verdict == .rejected(.argvLooksLikeShellWrapper))
    }

    /// An argv that trips both grounds at once: `zsh -lc "claude …"` read by the
    /// codex hook is a shell dispatcher AND another agent. The record must name
    /// the ground that stands on its own — the `-c` invocation is not a launch
    /// for any kind, while the kind mismatch is only true of this hook — rather
    /// than whichever check the implementation happens to run first.
    @Test func namesTheGroundThatHoldsWhenTwoGroundsApply() {
        let arguments = ["/bin/zsh", "-lc", "claude --resume abc"]
        // Both grounds really do hold for this capture, not just the one asserted.
        #expect(AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(arguments))
        #expect(!AgentLaunchCaptureTrust.nativeProcessDescribesKind(
            processName: "claude",
            arguments: arguments,
            kind: "codex"
        ))

        let verdict = AgentLaunchCaptureArgvVerdict(
            processName: "claude",
            arguments: arguments,
            kind: "codex"
        )
        #expect(verdict == .rejected(.argvLooksLikeShellWrapper))
    }

    /// The same argv under the kind it does describe still names the shell
    /// ground, which is what makes it the unconditional one: removing the
    /// mismatch does not change the answer.
    @Test func theShellGroundSurvivesRemovingTheOtherGround() {
        let arguments = ["/bin/zsh", "-lc", "claude --resume abc"]
        #expect(AgentLaunchCaptureTrust.nativeProcessDescribesKind(
            processName: "claude",
            arguments: arguments,
            kind: "claude"
        ))

        let verdict = AgentLaunchCaptureArgvVerdict(
            processName: "claude",
            arguments: arguments,
            kind: "claude"
        )
        #expect(verdict == .rejected(.argvLooksLikeShellWrapper))
    }

    /// The PID was unresolved or the process had already exited.
    @Test(arguments: [nil, []] as [[String]?])
    func namesTheGroundWhenThereIsNoArgvToJudge(arguments: [String]?) {
        let verdict = AgentLaunchCaptureArgvVerdict(
            processName: nil,
            arguments: arguments,
            kind: "codex"
        )
        #expect(verdict == .rejected(.argvUnavailable))
    }

    /// Two candidates, both discarded: the cmux launch capture names the record.
    /// The fallback's ground is often an artefact of the hook's own dispatch —
    /// hooks run under `sh -c …`, so a PID fallback reads as a shell wrapper for
    /// reasons unrelated to the agent — and letting it win would bury the
    /// ancestor-leak case the field exists to expose.
    @Test func theCmuxCaptureNamesTheRecordWhenBothCandidatesWereDiscarded() {
        #expect(
            AgentLaunchCaptureRejectionReason.recorded(
                cmuxCapture: .launcherDoesNotDescribeKind,
                processFallback: .argvLooksLikeShellWrapper
            ) == .launcherDoesNotDescribeKind
        )
    }

    /// With no cmux capture to reject, the fallback is the only candidate there
    /// was, so its ground is the record's.
    @Test func theFallbackNamesTheRecordWhenThereWasNoCmuxCapture() {
        #expect(
            AgentLaunchCaptureRejectionReason.recorded(
                cmuxCapture: nil,
                processFallback: .argvLooksLikeShellWrapper
            ) == .argvLooksLikeShellWrapper
        )
        #expect(
            AgentLaunchCaptureRejectionReason.recorded(
                cmuxCapture: nil,
                processFallback: .nativeProcessDoesNotDescribeKind
            ) == .nativeProcessDoesNotDescribeKind
        )
    }

    /// Neither candidate existed: nothing was rejected, there was nothing to read.
    @Test func noCandidateAtAllIsItsOwnGround() {
        #expect(
            AgentLaunchCaptureRejectionReason.recorded(
                cmuxCapture: nil,
                processFallback: nil
            ) == .argvUnavailable
        )
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
                let verdict = AgentLaunchCaptureArgvVerdict(
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
