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
        // A late duplicate of an already-counted message is ignored.
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", input: 2, cacheCreation: 1000, cacheRead: 50000, output: 100))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelID == "claude-opus-4-8")
        #expect(snapshot.modelDisplayName == "Opus 4.8")
        #expect(snapshot.contextTokens == 53003)
        #expect(snapshot.contextWindow == 1_000_000)
        // msg_a: 2*$5 + 1000*$6.25 + 50000*$0.50 + 100*$25   = $0.033760
        // msg_b: 3*$5 + 2000*$10 (1h write) + 51000*$0.50 + 400*$25 = $0.055515
        let cost = try #require(snapshot.estimatedCostUSD)
        #expect(abs(cost - 0.089275) < 1e-9)
        let fraction = try #require(snapshot.contextFraction)
        #expect(abs(fraction - 0.053003) < 1e-9)
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
        let cost = try #require(snapshot.estimatedCostUSD)
        #expect(abs(cost - 0.0299) < 1e-9)
    }

    @Test func claudeUnknownModelOmitsCostButKeepsContext() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .claude)
        accumulator.ingest(line: Fixture.claudeAssistant(id: "msg_a", model: "claude-mystery-9", input: 5, cacheRead: 100000, output: 1))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelDisplayName == "Mystery 9")
        #expect(snapshot.estimatedCostUSD == nil)
        #expect(snapshot.contextWindow == 200_000)
        #expect(abs(try #require(snapshot.contextFraction) - 0.500025) < 1e-9)
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

    @Test func codexUsesLatestTokenCountAndTurnContextModel() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .codex)
        accumulator.ingest(line: Fixture.codexTurnContext(model: "gpt-5-codex"))
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 20000, totalCached: 0, totalOutput: 500, lastTotal: 20500, window: 272_000
        ))
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 120_000, totalCached: 100_000, totalOutput: 5000, lastTotal: 30000, window: 272_000
        ))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.modelDisplayName == "gpt-5-codex")
        #expect(snapshot.contextTokens == 30000)
        #expect(snapshot.contextWindow == 272_000)
        // Cached input is part of input_tokens: 20000*$1.25 + 100000*$0.125 + 5000*$10 = $0.0875
        let cost = try #require(snapshot.estimatedCostUSD)
        #expect(abs(cost - 0.0875) < 1e-9)
    }

    @Test func codexUnknownModelKeepsReportedWindowWithoutCost() throws {
        var accumulator = AgentUsageTranscriptAccumulator(source: .codex)
        accumulator.ingest(line: Fixture.codexTurnContext(model: "gpt-6-astra"))
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 18345, totalCached: 0, totalOutput: 5, lastTotal: 18350, window: 258_400
        ))

        let snapshot = try #require(accumulator.snapshot())
        #expect(snapshot.estimatedCostUSD == nil)
        #expect(snapshot.contextWindow == 258_400)
        #expect(snapshot.contextTokens == 18350)
    }

    @Test func codexWithoutModelYieldsNoSnapshot() {
        var accumulator = AgentUsageTranscriptAccumulator(source: .codex)
        accumulator.ingest(line: Fixture.codexTokenCount(
            totalInput: 1, totalCached: 0, totalOutput: 1, lastTotal: 2, window: 100
        ))
        #expect(accumulator.snapshot() == nil)
    }
}
