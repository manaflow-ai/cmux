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
    private static let recentResponseLimit = ChatUsageAccumulator.recentResponseIdentityLimit

    // MARK: - Fixtures

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
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
        threadID: String = "t-1",
        turnID: String = "turn-1",
        omitTurnID: Bool = false,
        omitResponseID: Bool = false
    ) -> String {
        var payload: [String: Any] = [
            "thread_id": threadID, "session_id": "s-1",
            "usage": [
                "input_tokens": input,
                "cached_input_tokens": cached,
                "cache_write_input_tokens": cacheWrite,
                "output_tokens": output,
                "reasoning_output_tokens": reasoning,
                "total_tokens": Self.saturatedSum(input, output),
            ],
        ]
        if !omitTurnID { payload["turn_id"] = turnID }
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
        lastCached: Int = 0,
        contextWindow: Int? = 258_400,
        usedPercent: Double? = nil,
        windowMinutes: Int = 10_080,
        resetsAt: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        secondaryWindowMinutes: Int = 10_080,
        spendControlReached: Bool? = nil,
        includeUsageInfo: Bool = true,
        includeLastUsage: Bool = true,
        includeLastTotal: Bool = true
    ) -> String {
        var lastUsage: [String: Any] = [
            "input_tokens": lastInput,
            "cached_input_tokens": lastCached,
            "cache_write_input_tokens": 0,
            "output_tokens": lastOutput,
            "reasoning_output_tokens": 0,
        ]
        if includeLastTotal {
            lastUsage["total_tokens"] = Self.saturatedSum(lastInput, lastOutput)
        }
        var info: [String: Any] = [
            "total_token_usage": [
                "input_tokens": cumulativeInput,
                "cached_input_tokens": cumulativeCached,
                "cache_write_input_tokens": 0,
                "output_tokens": cumulativeOutput,
                "reasoning_output_tokens": 0,
                "total_tokens": Self.saturatedSum(cumulativeInput, cumulativeOutput),
            ],
        ]
        if includeLastUsage { info["last_token_usage"] = lastUsage }
        if let contextWindow { info["model_context_window"] = contextWindow }
        var payload: [String: Any] = ["type": "token_count"]
        if includeUsageInfo { payload["info"] = info }
        if usedPercent != nil || secondaryUsedPercent != nil || spendControlReached != nil {
            var limits: [String: Any] = ["limit_id": "codex"]
            if let usedPercent {
                var primary: [String: Any] = [
                    "used_percent": usedPercent, "window_minutes": windowMinutes,
                ]
                if let resetsAt { primary["resets_at"] = resetsAt }
                limits["primary"] = primary
            }
            if let secondaryUsedPercent {
                limits["secondary"] = [
                    "used_percent": secondaryUsedPercent,
                    "window_minutes": secondaryWindowMinutes,
                ]
            }
            if let spendControlReached { limits["spend_control_reached"] = spendControlReached }
            payload["rate_limits"] = limits
        }
        return Self.json([
            "type": "event_msg", "ordinal": 30,
            "timestamp": "2026-09-28T07:37:47.579Z", "payload": payload,
        ])
    }

    private func codexTurnContextLine(
        model: String,
        turnID: String = "turn-1",
        threadID: String? = nil
    ) -> String {
        var payload: [String: Any] = [
            "turn_id": turnID, "cwd": "/tmp/x", "model": model,
        ]
        if let threadID { payload["thread_id"] = threadID }
        return Self.json([
            "type": "turn_context", "ordinal": 4,
            "timestamp": "2026-09-28T07:35:34.499Z",
            "payload": payload,
        ])
    }

    private func codexCompactedLine() -> String {
        return Self.json([
            "type": "compacted", "ordinal": 31,
            "timestamp": "2026-09-28T07:37:47.600Z",
            "payload": ["message": "history replaced"],
        ])
    }

    private func codexSessionMetaLine(
        model: String,
        sessionID: String = "session-1",
        inheritedHistory: Bool = false
    ) -> String {
        var payload: [String: Any] = ["id": sessionID, "model": model]
        if inheritedHistory {
            payload["thread_source"] = "subagent"
            payload["source"] = [
                "subagent": [
                    "thread_spawn": ["parent_thread_id": "parent-thread", "depth": 1],
                ],
            ]
        }
        return Self.json([
            "type": "session_meta", "ordinal": 0,
            "timestamp": "2026-09-28T07:35:00.000Z",
            "payload": payload,
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

    @Test("provider model names are aggregated into a bounded number of rows")
    func modelUsageRowsAreBounded() {
        let reports = ChatUsageAccumulator.usageModelBucketLimit + 20

        var claude = ChatUsageAccumulator()
        claude.ingest(claudeLines: (0..<reports).map { index in
            claudeLine(
                uuid: "claude-\(index)",
                messageID: "msg-\(index)",
                model: "claude-model-\(index)",
                input: 1,
                cacheRead: 0,
                cacheWrite: 0,
                output: 0
            )
        })
        #expect(claude.totals.usageByModel.count == ChatUsageAccumulator.usageModelBucketLimit)
        #expect(claude.totals.usageByModel.values.map(\.totalTokens).reduce(0, +) == reports)

        var codex = ChatUsageAccumulator()
        for index in 0..<reports {
            codex.ingest(codexLines: [
                codexTurnContextLine(
                    model: "codex-model-\(index)",
                    turnID: "turn-\(index)",
                    threadID: "thread-\(index)"
                ),
                codexRecordLine(
                    responseID: "response-\(index)",
                    input: 1,
                    cached: 0,
                    output: 0,
                    threadID: "thread-\(index)",
                    turnID: "turn-\(index)"
                ),
            ])
        }
        #expect(codex.totals.usageByModel.count == ChatUsageAccumulator.usageModelBucketLimit)
        #expect(codex.totals.usageByModel.values.map(\.totalTokens).reduce(0, +) == reports)
    }

    @Test("retained provider identities are bounded by UTF-8 size")
    func retainedProviderIdentitiesAreByteBounded() {
        let oversized = String(
            repeating: "x",
            count: ChatUsageAccumulator.retainedTranscriptStringByteLimit + 1
        )

        var claude = ChatUsageAccumulator()
        claude.ingest(claudeLine: claudeLine(uuid: "oversized", messageID: oversized))
        #expect(claude.totals.responses == 0)
        #expect(claude.totals.unidentifiedReports == 1)

        var codex = ChatUsageAccumulator()
        codex.ingest(codexLine: codexRecordLine(responseID: oversized))
        #expect(codex.codexSource == .none)
        #expect(codex.totals.responses == 0)
        #expect(codex.totals.unidentifiedReports == 1)
    }

    @Test("oversized UTF-8 model labels use the bounded overflow row")
    func oversizedModelLabelsUseOverflowBucket() {
        // The character count fits the former limit, but UTF-8 storage does not.
        let oversizedModel = String(
            repeating: "é",
            count: ChatUsageAccumulator.usageModelNameByteLimit / 2 + 1
        )
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLine: claudeLine(
            uuid: "oversized-model",
            model: oversizedModel,
            input: 1,
            cacheRead: 0,
            cacheWrite: 0,
            output: 0
        ))
        accumulator.ingest(codexLines: [
            codexTurnContextLine(model: oversizedModel, turnID: "turn-large", threadID: "thread-large"),
            codexRecordLine(
                responseID: "response-large",
                input: 1,
                cached: 0,
                output: 0,
                threadID: "thread-large",
                turnID: "turn-large"
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usageByModel.keys.sorted() == ["<other models>"])
        #expect(totals.usageByModel["<other models>"]?.totalTokens == 2)
    }

    @Test("mixed-provider model rows share one global bound")
    func mixedProviderModelUsageRowsAreBounded() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: (0..<40).map { index in
            claudeLine(
                uuid: "claude-mixed-\(index)",
                messageID: "claude-message-\(index)",
                model: "claude-mixed-model-\(index)",
                input: 1,
                cacheRead: 0,
                cacheWrite: 0,
                output: 0
            )
        })
        for index in 0..<40 {
            accumulator.ingest(codexLines: [
                codexTurnContextLine(
                    model: "codex-mixed-model-\(index)",
                    turnID: "mixed-turn-\(index)",
                    threadID: "mixed-thread-\(index)"
                ),
                codexRecordLine(
                    responseID: "mixed-response-\(index)",
                    input: 1,
                    cached: 0,
                    output: 0,
                    threadID: "mixed-thread-\(index)",
                    turnID: "mixed-turn-\(index)"
                ),
            ])
        }

        let totals = accumulator.totals
        #expect(totals.usageByModel.count == ChatUsageAccumulator.usageModelBucketLimit)
        #expect(totals.usageByModel["<other models>"] != nil)
        #expect(totals.usageByModel.values.map(\.totalTokens).reduce(0, +) == 80)
    }

    @Test("Claude model corrections release their old bounded row")
    func claudeModelCorrectionsReleaseOldRows() {
        let reports = ChatUsageAccumulator.usageModelBucketLimit + 2
        var accumulator = ChatUsageAccumulator()

        accumulator.ingest(claudeLines: (0..<reports).map { index in
            claudeLine(
                uuid: "claude-correction-\(index)",
                requestID: "corrected-request",
                messageID: "corrected-message",
                model: "corrected-model-\(index)",
                input: index + 1,
                cacheRead: 0,
                cacheWrite: 0,
                output: 0
            )
        })

        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.usage.freshInputTokens == reports)
        #expect(totals.usageByModel.keys.sorted() == ["corrected-model-\(reports - 1)"])
        #expect(totals.usageByModel["corrected-model-\(reports - 1)"]?.freshInputTokens == reports)
        #expect(totals.usageByModel["<other models>"] == nil)
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
        #expect(totals.usageByModel.keys.sorted() == ["claude-opus-5"])
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

    @Test("Codex last-token aggregate does not claim context occupancy")
    func codexLastTokenAggregateIsNotContextOccupancy() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 388_256, cumulativeOutput: 1_428,
                lastInput: 52_266, lastOutput: 133
            ),
        ])

        let totals = accumulator.totals
        // Codex has emitted `last_token_usage` as both response usage and an
        // aggregate depending on version. Neither shape identifies resident
        // context, so even its explicit total is not an occupancy metric.
        #expect(totals.contextTokens == nil)
        #expect(totals.contextWindowTokens == 258_400)
        #expect(totals.contextUsedFraction == nil)
    }

    @Test("Codex last-token component counts do not claim context occupancy")
    func codexLastTokenComponentsAreNotContextOccupancy() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 10_000, cumulativeOutput: 500,
                lastInput: 128, lastOutput: 32,
                includeLastTotal: false
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.contextTokens == nil)
        #expect(totals.contextWindowTokens == 258_400)
        #expect(totals.contextUsedFraction == nil)
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
        // The event supplies the declared window, but no authoritative
        // resident-context metric.
        #expect(totals.contextTokens == nil)
        #expect(totals.contextWindowTokens == 258_400)
    }

    @Test("summed Codex records reproduce the provider's own running total")
    func codexRecordSumMatchesCumulative() {
        var accumulator = ChatUsageAccumulator()
        // Both figures are read off one real rollout: the five per-response
        // record totals in order, and the `total_token_usage` its final
        // `token_count` event carried. The second is not computed from the
        // first, which is the whole point: it is the provider's own answer,
        // so it checks both the fixtures and the deduplication.
        let perResponse = [28_090, 28_278, 29_301, 34_719, 39_279]
        let providerCumulative = 159_667
        #expect(perResponse.reduce(0, +) == providerCumulative)

        accumulator.ingest(codexLines: perResponse.enumerated().map { index, total in
            codexRecordLine(responseID: "resp_\(index)", input: total - 10, cached: 0, output: 10)
        })
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: providerCumulative - 50, cumulativeOutput: 50,
                lastInput: 39_269, lastOutput: 10
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 5)
        #expect(totals.usage.totalTokens == providerCumulative)
    }

    @Test("a delayed Codex record uses its own turn model, not the latest context")
    func codexDelayedRecordKeepsTurnModel() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTurnContextLine(model: "model-a", turnID: "turn-a", threadID: "shared-thread"),
            codexTurnContextLine(model: "model-b", turnID: "turn-b", threadID: "shared-thread"),
            codexRecordLine(
                responseID: "response-a", input: 100, cached: 0, output: 10,
                threadID: "shared-thread", turnID: "turn-a"
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usageByModel["model-a"]?.totalTokens == 110)
        #expect(totals.usageByModel["model-b"] == nil)
    }

    @Test("a present unknown turn never falls back to another model")
    func codexUnknownTurnHasNoModelFallback() {
        var turnOnly = ChatUsageAccumulator()
        turnOnly.ingest(codexLines: [
            codexTurnContextLine(
                model: "turn-model", turnID: "known-turn", threadID: "shared-thread"
            ),
            codexRecordLine(
                responseID: "unknown-record", input: 100, cached: 0, output: 10,
                threadID: "shared-thread", turnID: "unknown-turn"
            ),
        ])
        #expect(turnOnly.totals.usageByModel.isEmpty)

        var session = ChatUsageAccumulator()
        session.ingest(codexLines: [
            codexSessionMetaLine(model: "session-model"),
            codexRecordLine(
                responseID: "session-record", input: 100, cached: 0, output: 10,
                threadID: "unknown-thread", turnID: "unknown-turn"
            ),
        ])
        #expect(session.totals.usageByModel.isEmpty)

        var identityFree = ChatUsageAccumulator()
        identityFree.ingest(codexLines: [
            codexSessionMetaLine(model: "session-model"),
            codexRecordLine(
                responseID: "identity-free-record", input: 100, cached: 0, output: 10,
                threadID: "unknown-thread", omitTurnID: true
            ),
        ])
        #expect(identityFree.totals.usageByModel["session-model"]?.totalTokens == 110)
    }

    @Test("an evicted turn model is left unattributed")
    func codexEvictedTurnDoesNotUseLatestThreadModel() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLine: codexSessionMetaLine(model: "session-model"))
        for index in 0...Self.recentResponseLimit {
            accumulator.ingest(codexLine: codexTurnContextLine(
                model: "turn-model-\(index)",
                turnID: "turn-\(index)",
                threadID: "shared-thread"
            ))
        }
        accumulator.ingest(codexLine: codexRecordLine(
            responseID: "evicted-turn-record", input: 100, cached: 0, output: 10,
            threadID: "shared-thread", turnID: "turn-0"
        ))

        let totals = accumulator.totals
        #expect(totals.usageByModel.isEmpty)
        #expect(totals.usageByModel["turn-model-\(Self.recentResponseLimit)"] == nil)
    }

    @Test("an oversized turn identity is not retained or attributed")
    func codexOversizedTurnIdentityIsUnattributed() {
        let oversizedTurn = String(
            repeating: "t",
            count: ChatUsageAccumulator.retainedTranscriptStringByteLimit + 1
        )
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "session-model"),
            codexTurnContextLine(
                model: "turn-model", turnID: oversizedTurn, threadID: "shared-thread"
            ),
            codexRecordLine(
                responseID: "oversized-turn-record", input: 100, cached: 0, output: 10,
                threadID: "shared-thread", turnID: oversizedTurn
            ),
        ])

        #expect(accumulator.totals.usageByModel.isEmpty)
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

    @Test("a retried request counts again even though the message id repeats")
    func claudeRetryCountsTwice() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(
                uuid: "a-1", requestID: "req_1", messageID: "msg_1",
                input: 10, cacheRead: 0, cacheWrite: 0, output: 100
            ),
            claudeLine(
                uuid: "a-2", requestID: "req_2", messageID: "msg_1",
                input: 10, cacheRead: 0, cacheWrite: 0, output: 100
            ),
        ])

        let totals = accumulator.totals
        // `requestId` is half the identity on purpose. Two requests are two
        // billed responses whatever message id they carry, so keying on the
        // message id alone would drop the second one.
        #expect(totals.responses == 2)
        #expect(totals.duplicateReports == 0)
        #expect(totals.usage.totalTokens == 220)
    }

    @Test("a streaming response's placeholder counts lose to its final counts")
    func claudeStreamingPlaceholderReplaced() {
        var accumulator = ChatUsageAccumulator()
        // One response, three lines, taken from a real transcript: while the
        // response streams, the early lines carry a placeholder output count
        // and only the last one carries what it actually generated.
        accumulator.ingest(claudeLines: [
            claudeLine(uuid: "a-1", output: 2),
            claudeLine(uuid: "a-2", output: 6_513, thinking: 1_503),
            claudeLine(uuid: "a-3", output: 6_513, thinking: 1_503),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.duplicateReports == 2)
        // Keeping the first copy would report 2 output tokens for a response
        // that generated 6,513, and no reasoning tokens at all.
        #expect(totals.usage.outputTokens == 6_513)
        #expect(totals.usage.reasoningOutputTokens == 1_503)
        #expect(totals.usage.totalTokens == 12 + 48_519 + 4_060 + 6_513)
        #expect(totals.usageByModel["claude-opus-5"]?.outputTokens == 6_513)
    }

    @Test("bounded Claude identities still upgrade a recent streaming response")
    func claudeBoundedIdentityWindowPreservesStreamingUpgrade() {
        var accumulator = ChatUsageAccumulator()
        for index in 0..<(Self.recentResponseLimit - 1) {
            accumulator.ingest(claudeLine: claudeLine(
                uuid: "filler-\(index)",
                requestID: "request-\(index)",
                messageID: "message-\(index)",
                input: 0,
                cacheRead: 0,
                cacheWrite: 0,
                output: 1
            ))
        }
        accumulator.ingest(claudeLine: claudeLine(
            uuid: "target-placeholder",
            requestID: "target-request",
            messageID: "target-message",
            input: 0,
            cacheRead: 0,
            cacheWrite: 0,
            output: 2
        ))
        accumulator.ingest(claudeLine: claudeLine(
            uuid: "overflow",
            requestID: "overflow-request",
            messageID: "overflow-message",
            input: 0,
            cacheRead: 0,
            cacheWrite: 0,
            output: 1
        ))

        // The target is recent even though the map is full, so its final
        // report replaces the placeholder instead of becoming a response.
        accumulator.ingest(claudeLine: claudeLine(
            uuid: "target-final",
            requestID: "target-request",
            messageID: "target-message",
            input: 0,
            cacheRead: 0,
            cacheWrite: 0,
            output: 100
        ))

        // The oldest filler is outside the retention window and counts as a
        // new response if it implausibly reappears this far away.
        accumulator.ingest(claudeLine: claudeLine(
            uuid: "evicted-repeat",
            requestID: "request-0",
            messageID: "message-0",
            input: 0,
            cacheRead: 0,
            cacheWrite: 0,
            output: 1
        ))

        let totals = accumulator.totals
        #expect(totals.responses == Self.recentResponseLimit + 2)
        #expect(totals.duplicateReports == 1)
        #expect(totals.usage.outputTokens == Self.recentResponseLimit + 101)
    }

    @Test("a record before the first turn context counts in the total, not the split")
    func codexRecordBeforeModelKnown() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexRecordLine(responseID: "resp_1", input: 1_000, cached: 0, output: 100),
            codexTurnContextLine(model: "gpt-6-astra"),
            codexRecordLine(responseID: "resp_2", input: 2_000, cached: 0, output: 200),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 2)
        #expect(totals.usage.totalTokens == 3_300)
        // The first record had no model to attribute to yet, so the split is
        // short of the total even on this precise source. The tokens are not
        // lost, only unattributed.
        #expect(totals.usageByModel["gpt-6-astra"]?.totalTokens == 2_200)
        #expect(totals.usageByModel.count == 1)
    }

    @Test("compaction does not bank a lifetime cumulative counter")
    func codexCompactionDoesNotBankCumulativeUsage() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexCompactedLine(),
            codexTokenCountLine(
                cumulativeInput: 150, cumulativeOutput: 0,
                lastInput: 50, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.totalTokens == 150)
        #expect(totals.duplicateReports == 0)
        #expect(!totals.cumulativeUsageIsAmbiguous)
    }

    @Test("an ambiguous inherited cumulative prefix survives record takeover")
    func codexAmbiguousInheritedPrefixSurvivesRecords() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexCompactedLine(),
            codexTokenCountLine(
                cumulativeInput: 30, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-1", input: 20, cached: 0, output: 0),
            codexTokenCountLine(
                cumulativeInput: 50, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        // Compaction did not reset the provider's lifetime counter. The drop
        // makes the 30-token child prefix ambiguous, but does not make it
        // inherited parent usage or let the distinct record erase it.
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 50)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("an inherited pre-record thread total is not charged to the child transcript")
    func codexInheritedPreRecordThreadTotalIsDiscarded() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_086_500_386, cumulativeOutput: 3_819_683,
                lastInput: 25_589, lastOutput: 51,
                cumulativeCached: 22_656, lastCached: 22_656
            ),
            codexRecordLine(responseID: "resp-a", input: 25_589, cached: 22_656, output: 51),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 25_640)
        #expect(totals.usageByModel.isEmpty)
    }

    @Test("an inherited cumulative-only rollout counts growth, not its parent baseline")
    func codexInheritedCumulativeOnlyCountsGrowth() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000_000, cumulativeOutput: 20_000,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_000_025, cumulativeOutput: 20_005,
                lastInput: 25, lastOutput: 5
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.freshInputTokens == 25)
        #expect(totals.usage.outputTokens == 5)
        #expect(!totals.cumulativeUsageIsAmbiguous)
    }

    @Test("an inherited first cumulative event counts its proven child response")
    func codexInheritedFirstCumulativeCountsLastUsage() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_025, cumulativeOutput: 5,
                lastInput: 25, lastOutput: 5
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.freshInputTokens == 25)
        #expect(totals.usage.outputTokens == 5)
        #expect(!totals.cumulativeUsageIsAmbiguous)
    }

    @Test("a distinct first record preserves inherited child cumulative usage")
    func codexInheritedCumulativePrefixSurvivesDistinctRecord() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_020, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-after-prefix", input: 10, cached: 0, output: 0),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 30)
    }

    @Test("a matching first record replaces the inherited cumulative tail")
    func codexInheritedMatchingRecordReplacesCumulativeTail() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_020, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-matching-tail", input: 20, cached: 0, output: 0),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 20)
    }

    @Test("an equal-total record with different fields is not the cumulative tail")
    func codexInheritedEqualTotalDistinctRecordPreservesTail() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_010, cumulativeOutput: 10,
                lastInput: 10, lastOutput: 10
            ),
            codexRecordLine(responseID: "equal-total-distinct", input: 20, cached: 0, output: 0),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.usage.freshInputTokens == 30)
        #expect(totals.usage.outputTokens == 10)
        #expect(totals.usage.totalTokens == 40)
    }

    @Test("a less-informative duplicate cumulative snapshot preserves its tail")
    func codexInheritedDuplicateWithoutLastUsagePreservesTail() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_020, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_020, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0,
                includeLastUsage: false
            ),
            codexRecordLine(responseID: "record-after-duplicate", input: 20, cached: 0, output: 0),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.usage.totalTokens == 20)
        #expect(totals.duplicateReports == 1)
    }

    @Test("an inherited explicit zero starts a fully countable cumulative run")
    func codexInheritedZeroStartsCountableRun() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_020, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 0, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 30, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.freshInputTokens == 50)
        #expect(!totals.cumulativeUsageIsAmbiguous)
    }

    @Test("camel-case mixed-case subagent metadata discards the inherited prefix")
    func codexCamelCaseSubagentMetadataDiscardsPrefix() {
        let metadata = Self.json([
            "type": "session_meta",
            "payload": [
                "id": "session-child",
                "model": "",
                "threadSource": "SubAgent",
            ],
        ])
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            metadata,
            codexTokenCountLine(
                cumulativeInput: 1_000_000, cumulativeOutput: 20_000,
                lastInput: 0, lastOutput: 0
            ),
            codexRecordLine(responseID: "child-response", input: 25, cached: 0, output: 5),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 30)
    }

    @Test("cumulative events after records begin do not move the total")
    func codexEventsAfterRecordsDoNotMoveTheTotal() {
        var accumulator = ChatUsageAccumulator()
        let lines = [
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-1", input: 20, cached: 0, output: 0),
            codexTokenCountLine(
                cumulativeInput: 120, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-2", input: 30, cached: 0, output: 0),
            // A drop: a second thread counting from zero.
            codexTokenCountLine(
                cumulativeInput: 30, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-3", input: 40, cached: 0, output: 0),
            codexTokenCountLine(
                cumulativeInput: 70, cumulativeOutput: 0,
                lastInput: 40, lastOutput: 0
            ),
        ]
        accumulator.ingest(codexLines: lines)

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 3)
        #expect(totals.usage.totalTokens == 190)

        // Re-reading remains idempotent: post-transition cumulative events
        // are ignored and duplicate records do not change either component.
        var replayed = ChatUsageAccumulator()
        replayed.ingest(codexLines: lines)
        replayed.ingest(codexLines: lines)
        #expect(replayed.totals.usage.totalTokens == 190)
        #expect(replayed.totals.responses == 3)
    }

    @Test("same-rollout cumulative usage before record support stays counted")
    func codexSameRolloutCumulativePrefixIsRetained() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "gpt-6-astra"),
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexRecordLine(responseID: "resp-1", input: 20, cached: 0, output: 0),
        ])

        #expect(accumulator.totals.usage.totalTokens == 120)

        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 150, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
            codexRecordLine(responseID: "resp-2", input: 30, cached: 0, output: 0),
        ])

        #expect(accumulator.totals.usage.totalTokens == 150)
        #expect(accumulator.totals.responses == 2)
    }

    @Test("an unchanged cumulative snapshot cannot erase a record-only compaction")
    func codexRecordOnlyCompactionAfterCumulativeTransition() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-1", input: 20, cached: 0, output: 0),
            codexTokenCountLine(
                cumulativeInput: 120, cumulativeOutput: 0,
                lastInput: 20, lastOutput: 0
            ),
            // A compaction response is reported precisely, while the next
            // cumulative snapshot repeats the prior thread total.
            codexRecordLine(responseID: "record-2", input: 30, cached: 0, output: 0),
            codexTokenCountLine(
                cumulativeInput: 120, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 2)
        #expect(totals.usage.totalTokens == 150)
    }

    @Test("an explicit cumulative zero banks the current run without activating an empty stream")
    func codexExplicitZeroDelimitsCumulativeRuns() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLine: codexTokenCountLine(
            cumulativeInput: 0, cumulativeOutput: 0,
            lastInput: 0, lastOutput: 0
        ))
        #expect(accumulator.codexSource == .none)
        #expect(accumulator.totals.usage.isEmpty)

        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 0, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 150, cumulativeOutput: 0,
                lastInput: 150, lastOutput: 0
            ),
        ])

        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(accumulator.totals.usage.totalTokens == 250)
    }

    @Test("a structured boundary banks a new cumulative thread even when its first total is larger")
    func codexStructuredBoundaryBanksLargerNewRun() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTurnContextLine(
                model: "gpt-6-astra", turnID: "turn-old", threadID: "thread-old"
            ),
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexTurnContextLine(
                model: "gpt-6-astra", turnID: "turn-new", threadID: "thread-new"
            ),
            codexTokenCountLine(
                cumulativeInput: 150, cumulativeOutput: 0,
                lastInput: 150, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usage.totalTokens == 250)
        #expect(!totals.cumulativeUsageIsAmbiguous)
    }

    @Test("an unmarked cumulative decrease exposes ambiguity instead of guessing a run")
    func codexUnmarkedCumulativeDecreaseIsAmbiguous() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 30, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usage.totalTokens == 30)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("an equal-total cumulative correction is not a duplicate")
    func codexEqualTotalCumulativeCorrectionIsAmbiguous() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 80, cumulativeOutput: 20,
                lastInput: 80, lastOutput: 20
            ),
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usage.freshInputTokens == 100)
        #expect(totals.usage.outputTokens == 0)
        #expect(totals.duplicateReports == 0)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("a higher cumulative total with a reset component is ambiguous")
    func codexHigherTotalComponentResetIsAmbiguous() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 80, cumulativeOutput: 20,
                lastInput: 80, lastOutput: 20
            ),
            codexTokenCountLine(
                cumulativeInput: 120, cumulativeOutput: 0,
                lastInput: 120, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usage.freshInputTokens == 120)
        #expect(totals.usage.outputTokens == 0)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("inherited cumulative growth with a reset component is ambiguous")
    func codexInheritedHigherTotalComponentResetIsAmbiguous() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_080, cumulativeOutput: 20,
                lastInput: 80, lastOutput: 20
            ),
            codexTokenCountLine(
                cumulativeInput: 1_120, cumulativeOutput: 0,
                lastInput: 120, lastOutput: 0
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.usage.freshInputTokens == 120)
        #expect(totals.usage.outputTokens == 0)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("record takeover preserves inherited component-reset ambiguity")
    func codexRecordTakeoverPreservesInheritedComponentResetAmbiguity() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexSessionMetaLine(model: "", inheritedHistory: true),
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 1_080, cumulativeOutput: 20,
                lastInput: 80, lastOutput: 20
            ),
            codexTokenCountLine(
                cumulativeInput: 1_120, cumulativeOutput: 0,
                lastInput: 120, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-after-component-reset", input: 120, cached: 0, output: 0),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 120)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("a preserved ambiguous cumulative prefix stays ambiguous in record mode")
    func codexAmbiguousCumulativePrefixRemainsAmbiguousWithRecords() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 100, cumulativeOutput: 0,
                lastInput: 100, lastOutput: 0
            ),
            codexTokenCountLine(
                cumulativeInput: 30, cumulativeOutput: 0,
                lastInput: 30, lastOutput: 0
            ),
            codexRecordLine(responseID: "record-after-ambiguous-prefix", input: 20, cached: 0, output: 0),
        ])

        let totals = accumulator.totals
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.usage.totalTokens == 50)
        #expect(totals.cumulativeUsageIsAmbiguous)
    }

    @Test("Codex response identity retention is bounded")
    func codexResponseIdentityRetentionIsBounded() {
        var accumulator = ChatUsageAccumulator()
        for index in 0...Self.recentResponseLimit {
            accumulator.ingest(codexLine: codexRecordLine(
                responseID: "response-\(index)", input: 1, cached: 0, output: 0
            ))
        }

        accumulator.ingest(codexLine: codexRecordLine(
            responseID: "response-\(Self.recentResponseLimit)",
            input: 1,
            cached: 0,
            output: 0
        ))
        accumulator.ingest(codexLine: codexRecordLine(
            responseID: "response-0", input: 1, cached: 0, output: 0
        ))

        let totals = accumulator.totals
        #expect(totals.responses == Self.recentResponseLimit + 2)
        #expect(totals.duplicateReports == 1)
    }

    @Test("a record whose counts cannot be read does not zero the session")
    func codexUnreadableRecordKeepsCumulative() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 100_000, cumulativeOutput: 500,
                lastInput: 4_000, lastOutput: 100
            ),
            Self.json([
                "type": "token_usage_record", "ordinal": 31,
                "payload": [
                    "response_id": "resp_1",
                    // Renamed count keys: readable JSON, unreadable counts.
                    "usage": ["prompt_tokens": 1_000, "completion_tokens": 100],
                ],
            ]),
        ])

        let totals = accumulator.totals
        // Letting the record take over would swap a 100,500-token session for
        // a zero one, which reads as a session that spent nothing.
        #expect(totals.unidentifiedReports == 1)
        #expect(accumulator.codexSource == .cumulativeEvents)
        #expect(totals.usage.totalTokens == 100_500)
        #expect(totals.responses == 0)
    }

    @Test("an unreadable cumulative block does not disturb record mode")
    func codexUnreadableCumulativeKeepsRecordSource() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexRecordLine(responseID: "record-1", input: 100, cached: 0, output: 10),
            Self.json([
                "type": "event_msg", "ordinal": 30,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "prompt_tokens": 100,
                            "completion_tokens": 10,
                        ],
                    ],
                ],
            ]),
        ])

        let totals = accumulator.totals
        // The source remains precise, while the unreadable cumulative report
        // stays visible as a format mismatch.
        #expect(accumulator.codexSource == .usageRecords)
        #expect(totals.unidentifiedReports == 1)
        #expect(totals.responses == 1)
        #expect(totals.usage.totalTokens == 110)
    }

    @Test("one accumulator holds one transcript, so callers sum per transcript")
    func oneAccumulatorPerTranscript() {
        // Response ids are unique within a rollout, not across rollouts. Two
        // that share one would count it once in a shared accumulator, so the
        // supported shape is one accumulator each.
        let first = [codexRecordLine(responseID: "resp_1", input: 1_000, cached: 0, output: 100)]
        let second = [codexRecordLine(responseID: "resp_1", input: 2_000, cached: 0, output: 200)]

        var shared = ChatUsageAccumulator()
        shared.ingest(codexLines: first)
        shared.ingest(codexLines: second)
        #expect(shared.totals.responses == 1)
        #expect(shared.totals.usage.totalTokens == 1_100)

        var a = ChatUsageAccumulator()
        a.ingest(codexLines: first)
        var b = ChatUsageAccumulator()
        b.ingest(codexLines: second)
        #expect((a.totals.usage + b.totals.usage).totalTokens == 3_300)
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

    @Test("both allowance windows are read, and the tighter one is the one to show")
    func codexSecondaryRateLimitWindow() throws {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 10,
                lastInput: 1_000, lastOutput: 10,
                usedPercent: 12.0, windowMinutes: 300, resetsAt: 1_791_169_768,
                secondaryUsedPercent: 96.5, secondaryWindowMinutes: 10_080,
                spendControlReached: true
            ),
        ])

        let limit = try #require(accumulator.totals.rateLimit)
        #expect(limit.primary?.usedPercent == 12.0)
        #expect(limit.primary?.windowMinutes == 300)
        let secondary = try #require(limit.secondary)
        #expect(secondary.usedPercent == 96.5)
        #expect(secondary.windowMinutes == 10_080)
        #expect(limit.spendControlReached == true)
        // The weekly window is the one that stops a day of work, so a caller
        // showing one number shows 96.5%, not the five-hour window's 12%.
        #expect(limit.tightestWindow?.usedPercent == 96.5)
    }

    @Test("a spend-control-only snapshot is retained without inventing a window")
    func codexSpendControlOnlyRateLimit() throws {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 0, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0,
                spendControlReached: true,
                includeUsageInfo: false
            ),
        ])

        let limit = try #require(accumulator.totals.rateLimit)
        #expect(limit.primary == nil)
        #expect(limit.secondary == nil)
        #expect(limit.tightestWindow == nil)
        #expect(limit.spendControlReached == true)

        var explicitFalse = ChatUsageAccumulator()
        explicitFalse.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 0, cumulativeOutput: 0,
                lastInput: 0, lastOutput: 0,
                spendControlReached: false,
                includeUsageInfo: false
            ),
        ])
        #expect(explicitFalse.totals.rateLimit?.spendControlReached == false)
    }

    @Test("an omitted spend-control flag remains unknown")
    func codexMissingSpendControlRemainsUnknown() throws {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLines: [
            codexTokenCountLine(
                cumulativeInput: 1_000, cumulativeOutput: 10,
                lastInput: 1_000, lastOutput: 10,
                usedPercent: 37.5
            ),
        ])

        let limit = try #require(accumulator.totals.rateLimit)
        #expect(limit.primary?.usedPercent == 37.5)
        #expect(limit.spendControlReached == nil)
    }

    @Test("the complete public rate-limit and nested source APIs remain available")
    func publicUsageAPICompatibility() {
        let primary = ChatUsageRateLimit.Window(
            usedPercent: 12,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 100)
        )
        let secondary = ChatUsageRateLimit.Window(
            usedPercent: 96,
            windowMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 200)
        )
        var limit = ChatUsageRateLimit(
            primary: primary,
            secondary: secondary,
            spendControlReached: true
        )
        limit.usedPercent = 13
        limit.windowMinutes = 301
        limit.resetsAt = Date(timeIntervalSince1970: 101)

        #expect(limit.primary?.usedPercent == 13)
        #expect(limit.primary?.windowMinutes == 301)
        #expect(limit.primary?.resetsAt == Date(timeIntervalSince1970: 101))
        #expect(limit.secondary == secondary)
        #expect(limit.spendControlReached == true)
        #expect(limit.tightestWindow == secondary)

        let primaryOnly = ChatUsageRateLimit(usedPercent: 25, windowMinutes: 60)
        #expect(primaryOnly.primary?.usedPercent == 25)
        #expect(primaryOnly.secondary == nil)
        let source: ChatUsageAccumulator.CodexSource = .usageRecords
        #expect(source == .usageRecords)
        #expect(source == ChatUsageCodexSource.usageRecords)
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
    @Test("a usage block with no readable count is reported, not counted as zero")
    func claudeUnreadableCountsAreUnidentified() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            Self.json([
                "type": "assistant", "uuid": "a-1", "requestId": "req_1",
                "message": [
                    "id": "msg_1", "role": "assistant", "model": "claude-opus-5",
                    // Counts written as strings. This is what a provider
                    // format change looks like from in here: the line parses,
                    // the numbers do not.
                    "usage": ["input_tokens": "12", "output_tokens": "217"],
                ],
            ]),
        ])

        let totals = accumulator.totals
        // Counting it would report a response that cost nothing, which is
        // indistinguishable from a cheap turn. The count says otherwise.
        #expect(totals.unidentifiedReports == 1)
        #expect(totals.responses == 0)
        #expect(totals.usage.isEmpty)
    }

    @Test("a count too large for an integer is ignored rather than trapping")
    func outOfRangeCountIgnored() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            Self.json([
                "type": "assistant", "uuid": "a-1", "requestId": "req_1",
                "message": [
                    "id": "msg_1", "role": "assistant", "model": "claude-opus-5",
                    "usage": ["input_tokens": 1e30, "output_tokens": 217],
                ],
            ]),
        ])

        // Transcripts are written by remote and cloud hosts, so a count no
        // `Int` can hold is untrusted input, not a crash. The fields that do
        // parse still count.
        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.usage.freshInputTokens == 0)
        #expect(totals.usage.outputTokens == 217)
    }

    @Test("Int.max usage arithmetic and streaming upgrades saturate safely")
    func maximumUsageArithmeticAndStreamingStaySafe() {
        let maximum = ChatTokenUsage(
            freshInputTokens: Int.max,
            cacheReadTokens: Int.max,
            cacheWriteTokens: Int.max,
            outputTokens: Int.max,
            reasoningOutputTokens: Int.max
        )
        #expect(maximum.inputTokens == Int.max)
        #expect(maximum.totalTokens == Int.max)
        #expect(maximum + ChatTokenUsage(freshInputTokens: 1) == maximum)

        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(claudeLines: [
            claudeLine(
                uuid: "placeholder", input: 0, cacheRead: 0,
                cacheWrite: 0, output: 1
            ),
            claudeLine(
                uuid: "final", input: 0, cacheRead: 0,
                cacheWrite: 0, output: Int.max, thinking: Int.max
            ),
        ])

        let totals = accumulator.totals
        #expect(totals.responses == 1)
        #expect(totals.duplicateReports == 1)
        #expect(totals.usage.outputTokens == Int.max)
        #expect(totals.usage.reasoningOutputTokens == Int.max)
        #expect(totals.usage.totalTokens == Int.max)
    }

    @Test("Int.max Codex cache counts cannot overflow subtraction")
    func maximumCodexCacheCountsStaySafe() {
        var accumulator = ChatUsageAccumulator()
        accumulator.ingest(codexLine: codexRecordLine(
            responseID: "maximum",
            input: 0,
            cached: Int.max,
            cacheWrite: Int.max,
            output: Int.max,
            reasoning: Int.max
        ))

        let usage = accumulator.totals.usage
        #expect(usage.freshInputTokens == 0)
        #expect(usage.cacheReadTokens == Int.max)
        #expect(usage.cacheWriteTokens == Int.max)
        #expect(usage.outputTokens == Int.max)
        #expect(usage.totalTokens == Int.max)
    }

    @Test("recent identity collections stay at their configured capacity")
    func recentIdentityCollectionsStayBoundedAtScale() {
        let capacity = 128
        var set = RecentIDSet<Int>(capacity: capacity)
        var map = RecentIDMap<Int, Int>(capacity: capacity)
        for identity in 0..<100_000 {
            _ = set.insert(identity)
            map.setValue(identity, forKey: identity)
        }

        #expect(set.count == capacity)
        #expect(map.count == capacity)
        #expect(map.value(forKey: 0) == nil)
        #expect(map.value(forKey: 99_999) == 99_999)

        let oldestWasEvicted = set.insert(0)
        map.setValue(0, forKey: 0)
        #expect(oldestWasEvicted)
        #expect(set.count == capacity)
        #expect(map.count == capacity)
        #expect(map.value(forKey: 0) == 0)
    }
}
