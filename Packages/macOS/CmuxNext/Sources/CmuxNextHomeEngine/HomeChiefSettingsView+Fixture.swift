#if DEBUG
public import AppKit
import CmuxNextDaemon
import Foundation

/// A fixed brain answer for captures (`debug.chief_settings`, DEBUG builds): a capture mini runs
/// no Chief brain, so the Brain and Diagnostics cards would show nothing real to look at. The
/// fixture is a routed Claude harness (`claude-sr2-pipe`, which must read as a name), the
/// catalog's Opus and Sonnet, and one priced turn with cache reads and a failed tool call.
extension HomeChiefSettingsView {
    /// Shows the fixture as if the brain had answered it; the next real read replaces it.
    public func showCaptureFixture(now: Date = Date()) {
        let opus = ChiefEngineReport.Model(id: "claude-opus-5-5", name: "Claude Opus 5.5", family: "Opus", provider: "anthropic",
                                           shortName: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"],
                                           defaultEffort: "medium", fast: true, aliases: ["opus"], releaseDate: "2026-09-01")
        let sonnet = ChiefEngineReport.Model(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", family: "Sonnet", provider: "anthropic",
                                             shortName: "Sonnet 5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium",
                                             releaseDate: "2026-09-01")
        let ended = Int((now.timeIntervalSince1970 - 140) * 1000)
        let line = #"{"ev":"turn.end","ts":\#(ended),"status":"ok","harness":"claude-sr2-pipe","model":"claude-opus-5-5","#
            + #""effort":"high","ms":7840,"tools":4,"tool_errors":1,"cost_usd":0.1442,"#
            + #""usage":{"input":1200,"cache_read":18400,"cache_write":2400,"output":1850},"#
            + #""reply":{"prefix":"Both subagents are done; the fix is on the branch."}}"#
        var snapshot = HomeChiefSnapshot(harness: "claude-sr2-pipe", model: "claude-opus-5-5", effort: "high", avatar: nil,
                                         turns: HomeEngineTurn(line: line).map { [$0] } ?? [])
        snapshot.models = [opus, sonnet]
        snapshot.efforts = ["low", "medium", "high", "xhigh", "max"]
        snapshot.speeds = ["default"]
        snapshot.effective = ChiefEngineReport.Engine(harness: "claude-sr2-pipe", model: "claude-opus-5-5", effort: "high")
        show(snapshot)
    }

    /// Opens (or closes) Diagnostics' disclosure, as a click on it does.
    public func showDiagnosticsDetails(_ shown: Bool) {
        diagnosticsToggle.state = shown ? .on : .off
        toggleDiagnostics()
    }
}
#endif
