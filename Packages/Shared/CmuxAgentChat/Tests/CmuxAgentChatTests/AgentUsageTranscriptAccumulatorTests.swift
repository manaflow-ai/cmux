import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("AgentUsageTranscriptAccumulator")
struct AgentUsageTranscriptAccumulatorTests {
    private typealias Fixture = AgentUsageFixtures

    @Test func claudeCountsEachMessageOnceAndUsesLatestContext() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        // Claude Code repeats a message's usage on every content-block line;
        // the last line carries the final output count.
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 2, cacheCreation: 1000, cacheRead: 50000, output: 10))
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 2, cacheCreation: 1000, cacheRead: 50000, output: 100))
        accumulator.ingest(line: Fixture.claudeUserToolResult())
        accumulator.ingest(line: Fixture.claudeAssistant(
            id: "msg_b", input: 3, cacheCreation: 2000, cacheCreation1h: 2000, cacheRead: 51000, output: 400
        ))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelID == "claude-opus-4-8")
        #expect(snapshot.modelDisplayName == "Opus 4.8")
        #expect(snapshot.contextTokens == 53003)
        #expect(snapshot.contextWindow == 1_000_000)
        // msg_a: 2*$5 + 1000*$6.25 + 50000*$0.50 + 100*$25   = $0.033760
        // msg_b: 3*$5 + 2000*$10 (1h write) + 51000*$0.50 + 400*$25 = $0.055515
        let cost = try #require(snapshot.estimatedCost)
        #expect(abs(cost.usd - 0.089275) < 1e-9)
        #expect(!cost.isLowerBound)
        let fraction = try #require(snapshot.contextFraction)
        #expect(abs(fraction - 0.053003) < 1e-9)
    }

    @Test func interleavedLateLineUpdatesCostButNotContext() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 0, cacheRead: 1000, output: 10))
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_b", input: 0, cacheRead: 2000, output: 10))
        // A final line for msg_a arrives after msg_b began: its larger output
        // count replaces msg_a's earlier one, but the context stays msg_b's.
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 0, cacheRead: 1000, output: 1010))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.contextTokens == 2000)
        // cache reads 3000*$0.50 + output (1010 + 10)*$25 = $0.0270
        let cost = try #require(snapshot.estimatedCost)
        #expect(abs(cost.usd - 0.027) < 1e-9)
    }

    @Test func claudeSidechainAddsCostButNotContextOrModel() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 10, cacheRead: 40000, output: 20))
        accumulator.ingest(line: Fixture.claudeAssistant(
            id: "msg_sub", model: "claude-haiku-4-5-20251001", input: 100, cacheRead: 90000, output: 50, isSidechain: true
        ))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelDisplayName == "Opus 4.8")
        #expect(snapshot.contextTokens == 40010)
        // main: 10*$5 + 40000*$0.50 + 20*$25 = $0.02055
        // sub (Haiku): 100*$1 + 90000*$0.10 + 50*$5 = $0.00935
        let cost = try #require(snapshot.estimatedCost)
        #expect(abs(cost.usd - 0.0299) < 1e-9)
    }

    @Test func unknownModelMessageMakesCostALowerBound() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 0, cacheRead: 1000, output: 0))
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_b", model: "claude-mystery-9", input: 5, cacheRead: 100, output: 1))

        let snapshot = try #require(accumulator.snapshot())
        let cost = try #require(snapshot.estimatedCost)
        #expect(abs(cost.usd - 0.0005) < 1e-9)
        #expect(cost.isLowerBound)
    }

    @Test func onlyUnknownModelsOmitCostButKeepContext() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", model: "claude-mystery-9", input: 5, cacheRead: 100000, output: 1))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelDisplayName == "Mystery 9")
        #expect(snapshot.estimatedCost == nil)
        #expect(snapshot.contextWindow == 200_000)
        #expect(abs(try #require(snapshot.contextFraction) - 0.500025) < 1e-9)
    }

    @Test func skippedHistoryOmitsCostAndDroppedLineMakesItALowerBound() throws {
        var skipped = AgentUsageTranscriptAccumulator(source: .claude)
        skipped.markHistoryIncomplete()
        skipped.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 1, cacheRead: 10, output: 1))
        let skippedSnapshot = try #require(skipped.snapshot())
        #expect(skippedSnapshot.estimatedCost == nil)
        #expect(skippedSnapshot.contextTokens == 11)

        var dropped = AgentUsageTranscriptAccumulator(source: .claude)
        dropped.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 1, cacheRead: 10, output: 1))
        dropped.markLineDropped()
        #expect(try #require(dropped.snapshot()?.estimatedCost).isLowerBound)
    }

    @Test func claudeContextLargerThanTableWindowImpliesOneMillion() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeAssistant(
            id: "msg_a", model: "claude-sonnet-4-5-20250929", input: 1, cacheRead: 250_000, output: 1
        ))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.contextWindow == 1_000_000)
    }

    @Test func claudeIgnoresSyntheticModelAndNonUsageLines() {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeUserToolResult())
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_x", model: "<synthetic>", input: 0, output: 0))
        accumulator.ingest(line: "not json \"usage\"")
        #expect(accumulator.snapshot() == nil)
    }

    @Test func codexUsesLatestTokenCountWithoutReasoningAndNoCost() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .codex)
        accumulator.ingest(line: Fixture.codexTurnContext(model: "gpt-5-codex"))
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 20000, totalCached: 0, totalOutput: 500, lastTotal: 20500, window: 272_000
        ))
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 120_000, totalCached: 100_000, totalOutput: 5000, lastTotal: 30000, lastReasoning: 2000, window: 272_000
        ))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelDisplayName == "gpt-5-codex")
        #expect(snapshot.contextTokens == 28000)
        #expect(snapshot.contextWindow == 272_000)
        #expect(snapshot.estimatedCost == nil)
    }

    @Test func codexWithoutModelYieldsNoSnapshot() {
        var accumulator = AgentUsageTranscriptAccumulator(source: .codex)
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 1, totalCached: 0, totalOutput: 1, lastTotal: 2, window: 100
        ))
        #expect(accumulator.snapshot() == nil)
    }
}
