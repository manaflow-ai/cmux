import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture lines mirror the real transcript formats: Claude Code's
/// `~/.claude/projects/<cwd>/<session>.jsonl` and Codex's
/// `~/.codex/sessions/<date>/rollout-*.jsonl`. The token counts and the
/// repetition patterns are taken from real transcripts, because the bugs
/// this suite pins are all bugs of format interpretation rather than
/// arithmetic.
@Suite("ChatUsageAccumulator")
struct ChatUsageAccumulatorTests {
    // MARK: - Fixtures

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    /// One Claude assistant line. Every content block of a single response
    /// repeats the same `message.usage`, `message.id` and `requestId`, which
    /// is what the real format does.
    private func claudeLine(
        uuid: String,
        requestID: String = "req_1",
        messageID: String = "msg_1",
        model: String = "claude-opus-5",
        input: Int = 12,
        cacheRead: Int = 48_519,
        cacheWrite: Int = 4_060,
        output: Int = 217,
        thinking: Int? = nil,
        isSidechain: Bool = false,
        omitMessageID: Bool = false
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheWrite,
            "output_tokens": output,
            "service_tier": "standard",
        ]
        if let thinking {
            usage["output_tokens_details"] = ["thinking_tokens": thinking]
        }
        var message: [String: Any] = [
            "role": "assistant", "type": "message", "model": model,
            "content": [["type": "text", "text": "..."]],
            "usage": usage,
        ]
        if !omitMessageID { message["id"] = messageID }
        return Self.json([
            "type": "assistant", "uuid": uuid, "requestId": requestID,
            "isSidechain": isSidechain, "sessionId": "s-1",
            "timestamp": "2026-09-28T07:37:47.450Z",
            "message": message,
        ])
    }

    /// One Codex `token_usage_record` line, the per-response source.
    private func codexRecordLine(
        responseID: String,
        input: Int = 28_202,
        cached: Int = 27_904,
        cacheWrite: Int = 0,
        output: Int = 76,
        reasoning: Int = 0,
        omitResponseID: Bool = false
    ) -> String {
        var payload: [String: Any] = [
            "thread_id": "t-1", "turn_id": "turn-1", "session_id": "s-1",
            "usage": [
                "input_tokens": input,
                "cached_input_tokens": cached,
                "cache_write_input_tokens": cacheWrite,
                "output_tokens": output,
                "reasoning_output_tokens": reasoning,
                "total_tokens": input + output,
            ],
        ]
        if !omitResponseID { payload["response_id"] = responseID }
        return Self.json([
            "type": "token_usage_record", "ordinal": 27,
            "timestamp": "2026-09-28T07:37:47.450Z", "payload": payload,
        ])
    }

    /// One Codex `token_count` event. `total` is cumulative for the whole
    /// session; `last` is the most recent call only.
    private func codexTokenCountLine(
        cumulativeInput: Int,
        cumulativeOutput: Int,
        lastInput: Int,
        lastOutput: Int,
        cumulativeCached: Int = 0,
        contextWindow: Int? = 258_400,
        usedPercent: Double? = nil,
        windowMinutes: Int = 10_080,
        resetsAt: Double? = nil
    ) -> String {
        var info: [String: Any] = [
            "total_token_usage": [
                "input_tokens": cumulativeInput,
                "cached_input_tokens": cumulativeCached,
                "cache_write_input_tokens": 0,
                "output_tokens": cumulativeOutput,
                "reasoning_output_tokens": 0,
                "total_tokens": cumulativeInput + cumulativeOutput,
            ],
            "last_token_usage": [
                "input_tokens": lastInput,
                "cached_input_tokens": 0,
                "cache_write_input_tokens": 0,
                "output_tokens": lastOutput,
                "reasoning_output_tokens": 0,
                "total_tokens": lastInput + lastOutput,
            ],
        ]
        if let contextWindow { info["model_context_window"] = contextWindow }
        var payload: [String: Any] = ["type": "token_count", "info": info]
        if let usedPercent {
            var primary: [String: Any] = [
                "used_percent": usedPercent, "window_minutes": windowMinutes,
            ]
            if let resetsAt { primary["resets_at"] = resetsAt }
            payload["rate_limits"] = ["limit_id": "codex", "primary": primary]
        }
        return Self.json([
            "type": "event_msg", "ordinal": 30,
            "timestamp": "2026-09-28T07:37:47.579Z", "payload": payload,
        ])
    }

    private func codexTurnContextLine(model: String) -> String {
        Self.json([
            "type": "turn_context", "ordinal": 4,
            "timestamp": "2026-09-28T07:35:34.499Z",
            "payload": ["turn_id": "turn-1", "cwd": "/tmp/x", "model": model],
        ])
    }

    // MARK: - Claude: the repeated-response trap

    @Test("one Claude response repeated across its content blocks is counted once")
    func claudeContentBlockRepetitionCountedOnce() {
        var accumulator = ChatUsageAccumulator()
        // A thinking block, a text block and two tool calls: four lines, one
        // API response, four copies of the same usage. Summing them is the
        // 1.8x overstatement measured on real transcripts.
        accumulator.ingest(claudeLines: (1...4).map { claudeLine(uuid: "a-\($0)") })

        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.duplicateReports == 3)
        #expect(totals.usage.freshInputTokens == 12)
        #expect(totals.usage.cacheReadTokens == 48_519)
        #expect(totals.usage.cacheWriteTokens == 4_060)
        #expect(totals.usage.outputTokens == 217)
        #expect(totals.usage.totalTokens == 12 + 48_519 + 4_060 + 217)
    }

    @Test("distinct Claude responses each count, even with the same requestId")
    func claudeDistinctResponsesCount() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", requestID: "req_1", messageID: "msg_1", output: 10),
            claudeLine(uuid: "a-2", requestID: "req_1", messageID: "msg_2", output: 20),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 2)
        #expect(totals.duplicateReports == 0)
        #expect(totals.usage.outputTokens == 30)
    }

    @Test("Claude cache figures sit beside input rather than inside it")
    func claudeInputExcludesCache() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", input: 2, cacheRead: 48_519, cacheWrite: 4_060, output: 217),
        ])

        // The whole prompt was 52,581 tokens, only 2 of them fresh. Treating
        // `input_tokens` as the whole prompt would report 2.
        #expect(accumulator.totals.usage.freshInputTokens == 2)
        #expect(accumulator.totals.usage.inputTokens == 52_581)
    }

    @Test("subagent usage counts even though the conversation view hides it")
    func claudeSidechainUsageCounts() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", messageID: "msg_main", output: 100),
            claudeLine(uuid: "s-1", requestID: "req_2", messageID: "msg_side", output: 900, isSidechain: true),
        ])

        // ClaudeTranscriptParser drops sidechain lines because they are not
        // part of the visible conversation. Spend is not display: a
        // subagent's tokens were still spent.
        #expect(accumulator.totals.responses == 2)
        #expect(accumulator.totals.usage.outputTokens == 1_000)
    }

    @Test("Claude usage splits by model and thinking stays inside output")
    func claudeModelSplitAndThinking() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", messageID: "msg_1", model: "claude-opus-5", output: 300, thinking: 120),
            claudeLine(uuid: "a-2", messageID: "msg_2", model: "claude-fable-5-1", output: 40),
        ])

        let totals = accumulator.totals
        #expect(totals.usageByModel["claude-opus-5"]?.outputTokens == 300)
        #expect(totals.usageByModel["claude-fable-5-1"]?.outputTokens == 40)
        #expect(totals.usage.reasoningOutputTokens == 120)
        // Reasoning is a breakdown of output, never an addend.
        #expect(totals.usage.outputTokens == 340)
        #expect(totals.usage.totalTokens == totals.usage.inputTokens + 340)
    }

    @Test("a Claude usage block with no message id is skipped, not guessed")
    func claudeUnidentifiedUsageSkipped() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", output: 50, omitMessageID: true),
            claudeLine(uuid: "a-2", output: 50, omitMessageID: true),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 0)
        #expect(totals.unidentifiedReports == 2)
        #expect(totals.usage.isEmpty)
    }

    // MARK: - Codex: the cumulative trap

    @Test("Claude's synthetic client-side messages are not responses")
    func claudeSyntheticMessagesSkipped() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a"),
            claudeLine(
                uuid: "b", requestID: "req_2", messageID: "synthetic-1",
                model: "<synthetic>", input: 0, cacheRead: 0, cacheWrite: 0, output: 0
            ),
        ])
        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.usageByModel["<synthetic>"] == nil)
        #expect(totals.duplicateReports == 0)
        #expect(totals.unidentifiedReports == 0)
    }

    @Test("Codex cumulative totals are never summed")
    func codexCumulativeIsNotSummed() {
        var accumulator = ChatUsageAccumulator()
        // Real cumulative sequence from a rollout: the running total climbs
        // to 389,684 over eleven calls. Summing the eleven cumulative values
        // gives well over two million and exceeds the context window many
        // times over.
        let cumulative = [
            (28_021, 69), (56_223, 145), (85_372, 297), (119_908, 480),
            (159_092, 575), (198_383, 761), (241_287, 988), (288_575, 1_103),
            (335_990, 1_295), (335_990, 1_295), (388_256, 1_428),
        ]
        accumulator.ingest(codexLines: cumulative.map {
            codexTokenCountLine(
                cumulativeInput: $0.0, cumulativeOutput: $0.1,
                lastInput: 52_266, lastOutput: 133
            )
        })

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.totalTokens == 388_256 + 1_428)
        // The repeated cumulative value is recognized rather than added.
        #expect(totals.duplicateReports == 1)
    }

    @Test("Codex context occupancy comes from the last call, not the running total")
    func codexContextFromLastCall() throws {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 388_256, cumulativeOutput: 1_428,
                lastInput: 52_266, lastOutput: 133
            ),
        ])

        let totals = accumulator.totals
        // 388,256 cumulative against a 258,400 window would read as 150%
        // full. The prompt that is actually resident is 52,266 tokens.
        #expect(totals.contextTokens == 52_266)
        #expect(totals.contextWindowTokens == 258_400)
        let fraction = try #require(totals.contextUsedFraction)
        #expect(fraction > 0.20 && fraction < 0.21)
    }

    @Test("Codex input tokens include the cached part and are unpacked")
    func codexInputIncludesCache() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexRecordLine(responseID: "resp_1", input: 28_202, cached: 27_904, output: 76),
        ])

        let totals = accumulator.totals
        // Codex reports the whole prompt in `input_tokens`, so fresh input is
        // the remainder once the cached part is taken out. Mapping their
        // `input_tokens` onto Claude's meaning would claim 28,202 fresh
        // tokens when only 298 were.
        #expect(totals.usage.freshInputTokens == 298)
        #expect(totals.usage.cacheReadTokens == 27_904)
        #expect(totals.usage.inputTokens == 28_202)
        // Our derived total reproduces the provider's own `total_tokens`.
        #expect(totals.usage.totalTokens == 28_278)
    }

    @Test("Codex cache figures reported outside input clamp instead of going negative")
    func codexFreshInputClampsAtZero() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexRecordLine(responseID: "resp_1", input: 100, cached: 400, cacheWrite: 50, output: 10),
        ])

        // This shape should not happen today. It pins the behavior if Codex
        // ever moves the cache figures out of `input_tokens`: a zero, not a
        // negative that would silently reduce a sum.
        #expect(accumulator.totals.usage.freshInputTokens == 0)
        #expect(accumulator.totals.usage.outputTokens == 10)
    }

    @Test("per-response records win over the cumulative events for the same spend")
    func codexRecordsPreferredOverEvents() {
        var accumulator = ChatUsageAccumulator()
        // A real rollout carries both. The record at ordinal 27 and the event
        // at ordinal 30 describe the same call, so counting both doubles it.
        accumulator.ingest(codexLines: [
            codexTurnContextLine(model: "gpt-6-astra"),
            codexRecordLine(responseID: "resp_1", input: 28_021, cached: 0, output: 69),
            codexTokenCountLine(
                cumulativeInput: 28_021, cumulativeOutput: 69,
                lastInput: 28_021, lastOutput: 69
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 28_090)
        #expect(totals.usageByModel["gpt-6-astra"]?.totalTokens == 28_090)
        // The event still supplies context and window, which records lack.
        #expect(totals.contextTokens == 28_021)
        #expect(totals.contextWindowTokens == 258_400)
    }

    @Test("summed Codex records reproduce the provider's own running total")
    func codexRecordSumMatchesCumulative() {
        var accumulator = ChatUsageAccumulator()
        // Per-response totals taken from a real rollout, in order.
        let perResponse = [28_090, 28_278, 29_301, 34_719, 39_279]
        accumulator.ingest(codexLines: perResponse.enumerated().map { index, total in
            codexRecordLine(responseID: "resp_\(index)", input: total - 10, cached: 0, output: 10)
        })
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: perResponse.reduce(0, +) - 50, cumulativeOutput: 50,
                lastInput: 39_269, lastOutput: 10
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 5)
        // The provider's cumulative figure is the independent check on the
        // deduplicated per-response sum.
        #expect(totals.usage.totalTokens == perResponse.reduce(0, +))
    }

    @Test("a repeated Codex record is counted once")
    func codexRecordRepetitionCountedOnce() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexRecordLine(responseID: "resp_1", input: 1_000, cached: 0, output: 100),
            codexRecordLine(responseID: "resp_1", input: 1_000, cached: 0, output: 100),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.duplicateReports == 1)
        #expect(totals.usage.totalTokens == 1_100)
    }

    @Test("a Codex record with no response id is skipped, not guessed")
    func codexUnidentifiedRecordSkipped() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexRecordLine(responseID: "resp_1", input: 1_000, cached: 0, output: 100, omitResponseID: true),
        ])

        let totals = accumulator.totals
        #expect(totals.unidentifiedReports == 1)
        #expect(totals.usage.isEmpty)
        #expect(accumulator.codexSource == .none)
    }

    @Test("the cumulative fallback reports a total without claiming a model split")
    func codexCumulativeFallbackOmitsModelSplit() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTurnContextLine(model: "gpt-6-astra"),
            codexTokenCountLine(
                cumulativeInput: 10_000, cumulativeOutput: 500,
                lastInput: 4_000, lastOutput: 100
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.totalTokens == 10_500)
        // A cumulative figure cannot be attributed to a response or a model,
        // so the split stays empty rather than guessing the last model seen.
        #expect(totals.usageByModel.isEmpty)
        #expect(totals.responses == 0)
    }

    // MARK: - Rate limits

    @Test("Codex allowance state is read from the rate limit block")
    func codexRateLimit() throws {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 10,
                lastInput: 1_000, lastOutput: 10,
                usedPercent: 37.5, windowMinutes: 10_080, resetsAt: 1_791_169_768
            ),
        ])

        let limit = try #require(accumulator.totals.rateLimit)
        #expect(limit.usedPercent == 37.5)
        #expect(limit.windowMinutes == 10_080)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_791_169_768))
    }

    @Test("Claude transcripts carry no allowance state, so it stays absent")
    func claudeHasNoRateLimit() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [claudeLine(uuid: "a-1")])

        let totals = accumulator.totals
        // Claude Code does not write limit state into its transcript. A zero
        // percent would read as "plenty left", which we do not know.
        #expect(totals.rateLimit == nil)
        #expect(totals.contextTokens == nil)
        #expect(totals.contextWindowTokens == nil)
        #expect(totals.contextUsedFraction == nil)
    }

    // MARK: - Mixed, empty and malformed input

    @Test("both providers add into one set of totals")
    func mixedProviders() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [claudeLine(uuid: "a-1", input: 5, cacheRead: 0, cacheWrite: 0, output: 100)])
        accumulator.ingest(codexLines: [codexRecordLine(responseID: "resp_1", input: 200, cached: 0, output: 50)])

        let totals = accumulator.totals
        #expect(totals.responses == 2)
        #expect(totals.usage.outputTokens == 150)
        #expect(totals.usage.totalTokens == 5 + 100 + 200 + 50)
    }

    @Test("malformed, empty and usage-free lines are skipped without effect")
    func malformedLinesSkipped() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            "", "{not json", "[]", "{}",
            Self.json(["type": "user", "message": ["role": "user", "content": "hi"]]),
        ])
        accumulator.ingest(codexLines: [
            "", "{not json",
            Self.json(["type": "response_item", "payload": ["type": "message"]]),
            Self.json(["type": "event_msg", "payload": ["type": "agent_message"]]),
        ])

        let totals = accumulator.totals
        #expect(totals == ChatUsageTotals())
        #expect(accumulator.codexSource == .none)
    }

    @Test("an empty accumulator reports zeros and no context")
    func emptyAccumulator() {
        let totals = ChatUsageAccumulator().totals
        #expect(totals.usage.isEmpty)
        #expect(totals.responses == 0)
        #expect(totals.usageByModel.isEmpty)
        #expect(totals.contextUsedFraction == nil)
    }

    @Test("ingesting line by line matches ingesting the whole run")
    func incrementalMatchesBatch() {
        let lines = [
            claudeLine(uuid: "a-1", messageID: "msg_1", output: 10),
            claudeLine(uuid: "a-2", messageID: "msg_1", output: 10),
            claudeLine(uuid: "a-3", messageID: "msg_2", output: 20),
        ]

        var batch = ChatUsageAccumulator()
        batch.ingest(claudeLines: lines)

        var incremental = ChatUsageAccumulator()
        for line in lines { incremental.ingest(claudeLine: line) }

        // Callers tail a growing transcript, so a partial read followed by
        // the rest has to land on the same answer as one pass.
        #expect(incremental.totals == batch.totals)
        #expect(batch.totals.usage.outputTokens == 30)
    }

    @Test("negative counts from a malformed line cannot reduce a total")
    func negativeCountsClampToZero() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", input: -5, cacheRead: -10, cacheWrite: 0, output: -1),
        ])

        #expect(accumulator.totals.usage.isEmpty)
        #expect(accumulator.totals.responses == 1)
    }
}
