@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Leo 2026-10-21 (#89): the Chief Settings' Diagnostics card shows the last turn's time, tokens,
/// effort and error. `chief.engine.get`'s `recent` sends them (an older brain does not, and must
/// still decode), and this Mac's trace lines carry the same fields.
@MainActor @Suite struct HomeEngineTurnFieldsTests {
    /// The brain's turn summary (engine_control.rs `turn_summary`), as a newer brain sends it.
    static let newer = #"""
    {"engine": {"harness": "claude-sr2-pipe"}, "recent": [{"turn": 7, "ts": 1792600000000, "status": "error",
      "harness": "claude-sr2-pipe", "harness_profile": null, "model": "claude-opus-5-5", "effort": "high", "ms": 7840,
      "tools": 3, "tool_errors": 1, "cost_usd": null,
      "usage": {"input": 1000, "cache_read": 8000, "cache_write": 1000, "output": 2345},
      "reply": "Both subagents are done", "error": "harness exited"}]}
    """#

    /// An older brain's summary: no `ts`, `effort`, `error` or usage `output`.
    static let older = #"""
    {"engine": {}, "recent": [{"status": "ok", "harness": "claude", "model": "opus", "ms": 1200, "tools": 0,
      "tool_errors": 0, "cost_usd": 0.1442, "usage": {"input": 10, "cache_read": 10, "cache_write": 0}, "reply": "Done."}]}
    """#

    static func report(_ json: String) throws -> ChiefEngineReport {
        try JSONDecoder().decode(ChiefEngineReport.self, from: Data(json.utf8))
    }

    @Test func aNewerTurnSummaryDecodesItsNewFields() throws {
        let turn = try #require(try Self.report(Self.newer).recent.first)
        #expect(turn.ts == 1_792_600_000_000)
        #expect(turn.effort == "high")
        #expect(turn.error == "harness exited")
        #expect(turn.usage?.output == 2345)
        #expect(turn.usage?.cacheRead == 8000)
        #expect(turn.costUSD == nil)
    }

    @Test func anOlderTurnSummaryStillDecodes() throws {
        let turn = try #require(try Self.report(Self.older).recent.first)
        #expect(turn.ts == nil)
        #expect(turn.effort == nil)
        #expect(turn.error == nil)
        #expect(turn.usage?.output == nil)
        #expect(turn.costUSD == 0.1442)
    }

    @Test func aTurnCarriesItsTimeTokensAndError() throws {
        let turn = HomeEngineTurn(report: try #require(try Self.report(Self.newer).recent.first))
        #expect(turn.ended == Date(timeIntervalSince1970: 1_792_600_000))
        #expect(turn.tokens == 12_345)
        #expect(turn.hitRate == 0.8)
        #expect(turn.effort == "high")
        #expect(turn.error == "harness exited")
        // This Mac's trace line carries the same fields.
        let line = try #require(HomeEngineTurn(line: #"""
        {"ev":"turn.end","ts":1792600000000,"harness":"claude","effort":"low","ms":900,"error":{"prefix":"boom"},
         "usage":{"input":5,"cache_read":0,"cache_write":5,"output":10}}
        """#.replacingOccurrences(of: "\n", with: "")))
        #expect(line.ended == Date(timeIntervalSince1970: 1_792_600_000))
        #expect(line.tokens == 20)
        #expect(line.hitRate == 0)
        #expect(line.effort == "low")
        #expect(line.error == "boom")
    }
}
