import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The phone's read of acpmux's `composerStatus.facts` (RFD 0130): what a row says, what a census
/// row leaving the row-repeating facts out keeps, and how the card and counters word them.
@Suite struct ComposerFooterFactsTests {
    private func status(_ json: String) throws -> JSONValue {
        try #require(JSONValue(jsonData: Data(json.utf8)))
    }

    @Test func parsesEveryKindItKnowsAndSkipsNewerOnes() throws {
        let facts = AgentFooterFacts(composerStatus: try status("""
        {"items":[],"facts":[
          {"kind":"machine","text":"cosmic-gray","live":false,"atRest":true},
          {"kind":"folder","text":"/Users/leo/src/cmux","live":false},
          {"kind":"context","fraction":1.4,"live":false},
          {"kind":"turn","since":1700000000000,"live":false},
          {"kind":"subagents","count":3,"live":true},
          {"kind":"sparkles","text":"from a newer acpmux","live":true}
        ]}
        """))
        #expect(facts.facts.map(\.kind) == [.machine, .folder, .context, .turn, .subagents])
        #expect(facts.facts[0].atRest)
        #expect(facts.facts[2].fraction == 1)
        #expect(facts.facts[3].since == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(facts.live.map(\.kind) == [.subagents])
        #expect(AgentFooterFacts(composerStatus: nil).isEmpty)
    }

    @Test func aCensusRowKeepsTheRowFactsItLeavesOut() {
        let full = AgentFooterFacts([
            AgentFooterFact(kind: .machine, text: "cosmic-gray"),
            AgentFooterFact(kind: .branch, text: "main"),
            AgentFooterFact(kind: .queued, count: 1, live: true),
        ])
        let census = AgentFooterFacts([AgentFooterFact(kind: .subagents, count: 2, live: true)])
        let merged = full.updated(with: census)
        #expect(merged.facts.map(\.kind) == [.machine, .branch, .subagents])
        // A whole form replaces everything, the row facts with it.
        let whole = AgentFooterFacts([AgentFooterFact(kind: .folder, text: "a/b")])
        #expect(merged.updated(with: whole) == whole)
    }

    @Test func zeroCountsDrawNoCounter() {
        let facts = AgentFooterFacts([
            AgentFooterFact(kind: .subagents, count: 0, live: true),
            AgentFooterFact(kind: .queued, count: 12, live: true),
            AgentFooterFact(kind: .context, fraction: 0.5),
        ])
        #expect(facts.live.map(\.kind) == [.queued])
        #expect(facts.live.first?.countLabel == "9+")
        #expect(AgentFooterFact(kind: .subagents, count: 9, live: true).countLabel == "9")
    }

    @Test func cardValues() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(AgentFooterFact(kind: .folder, text: "/Users/leo/src/cmux").value(now: now) == "src/cmux")
        #expect(AgentFooterFact(kind: .folder, text: "~/cmux").value(now: now) == "~/cmux")
        #expect(AgentFooterFact(kind: .context, fraction: 0.426).value(now: now) == "43%")
        #expect(AgentFooterFact(kind: .turn, since: now.addingTimeInterval(-185)).value(now: now) == "3m 05s")
        #expect(AgentFooterFact(kind: .branch).value(now: now) == nil)
        #expect(AgentFooterFact.elapsed(42) == "42s")
        #expect(AgentFooterFact.elapsed(3720) == "1h 02m")
        #expect(AgentFooterFact.elapsed(-3) == "0s")
    }

    @Test func modeDefaultsOffAndReadsTheMacsStripAsPulse() {
        #expect(ComposerFooterFactsMode.stored(nil) == .off)
        #expect(ComposerFooterFactsMode.stored("nonsense") == .off)
        #expect(ComposerFooterFactsMode.stored("door") == .door)
        #expect(ComposerFooterFactsMode.stored("strip") == .pulse)
    }
}
