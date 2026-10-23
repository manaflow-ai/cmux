import AppKit
@testable import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Leo 2026-10-21 (#89): Diagnostics was a text dump. The Chief Settings' Diagnostics card shows
/// the last turn as measures: its time, its cost (its tokens when the harness gives no price),
/// the share of the prompt read from the cache, and its tool calls, from `chief.engine.get`'s
/// `recent` (whose newer fields an older brain does not send) or this Mac's trace.
@MainActor @Suite struct HomeChiefTurnSummaryTests {
    static let english = Locale(identifier: "en_US")

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

    @Test func measuresReadInTheReadersFormat() {
        let en = Self.english
        #expect(HomeChiefTurnSummary.cache(0.5, locale: en) == "50%")
        #expect(HomeChiefTurnSummary.cache(0.996, locale: en) == "100%")
        #expect(HomeChiefTurnSummary.cache(nil, locale: en) == HomeChiefTurnSummary.missing)
        #expect(HomeChiefTurnSummary.cost(0.1442, locale: en) == "$0.144")
        #expect(HomeChiefTurnSummary.cost(2.5, locale: en) == "$2.50")
        #expect(HomeChiefTurnSummary.cost(0.0004, locale: en) == "<$0.001")
        #expect(HomeChiefTurnSummary.cost(nil, locale: en) == nil)
        #expect(HomeChiefTurnSummary.tokens(12_345, locale: en) == "12.3K")
        #expect(HomeChiefTurnSummary.tokens(950, locale: en) == "950")
        #expect(HomeChiefTurnSummary.tokens(nil, locale: en) == nil)
        #expect(HomeChiefTurnSummary.seconds(7.84, locale: en) == "7.8s")
    }

    /// No price from the harness: the card shows the turn's tokens in its place, the engine by
    /// name, and a failed tool call under the tool count.
    @Test func aTurnWithNoPriceShowsItsTokens() throws {
        let turn = HomeEngineTurn(report: try #require(try Self.report(Self.newer).recent.first))
        let summary = HomeChiefTurnSummary(turn, models: HomeChiefModelMenuTests.claudeModels,
                                           now: Date(timeIntervalSince1970: 1_792_600_120), locale: Self.english)
        #expect(summary.engine == "\(ChiefBackend.claude.title) (SR2 Pipe) \u{00B7} Opus 5.5 \u{00B7} \(HomeEngineStrings.effortTitle("high"))")
        #expect(summary.metrics.map(\.label) == [HomeChiefCardStrings.time, HomeChiefCardStrings.tokens,
                                                 HomeChiefCardStrings.cache, HomeChiefCardStrings.tools])
        #expect(summary.metrics.map(\.value) == ["7.8s", "12.3K", "80%", "3"])
        #expect(summary.metrics.last?.note?.contains("1") == true)
        #expect(summary.error == "harness exited")
        #expect(summary.ended != nil)
    }

    @Test func aPricedTurnShowsItsCost() throws {
        let turn = HomeEngineTurn(report: try #require(try Self.report(Self.older).recent.first))
        let summary = HomeChiefTurnSummary(turn, locale: Self.english)
        #expect(summary.engine == "\(ChiefBackend.claude.title) \u{00B7} Opus")
        #expect(summary.metrics.map(\.label)[1] == HomeChiefCardStrings.cost)
        #expect(summary.metrics.map(\.value)[1] == "$0.144")
        #expect(summary.metrics.map(\.value)[2] == "50%")
        #expect(summary.metrics.last?.note == nil)
        #expect(summary.error == nil)
        #expect(summary.ended == nil)
    }

    /// The card shows the brain's last turn by name, and says what will show before the first.
    @Test func theDiagnosticsCardShowsTheLastTurn() throws {
        let home = FileManager.default.temporaryDirectory
        let view = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        view.show(HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: []))
        #expect(view.lastTurn.summary == nil)
        #expect(!view.lastTurn.empty.isHidden)
        let turn = HomeEngineTurn(report: try #require(try Self.report(Self.newer).recent.first))
        var snapshot = HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [turn])
        snapshot.models = HomeChiefModelMenuTests.claudeModels
        view.show(snapshot)
        #expect(view.lastTurn.empty.isHidden)
        #expect(view.lastTurn.tiles.count == 4)
        #expect(!view.lastTurn.engine.stringValue.contains("claude-"))
        #expect(!view.replies.stringValue.contains("claude-"))
        #expect(view.lastTurn.accessibilityLabel()?.contains("Opus 5.5") == true)
        #expect(!view.lastTurn.error.isHidden)
    }
}
