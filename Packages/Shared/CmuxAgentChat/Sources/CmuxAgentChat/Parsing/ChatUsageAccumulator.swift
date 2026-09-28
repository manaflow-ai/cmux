import Foundation

/// Accumulates normalized token usage from agent transcript JSONL lines.
///
/// Feed lines in transcript order, then read ``totals``. The accumulator is
/// incremental so a caller tailing a growing transcript can keep one value
/// across reads, the same way ``ChatTranscriptParseState`` works for
/// message parsing.
///
/// - Important: One accumulator holds one transcript. Response identities
///   and the Codex source decision are per transcript, so feeding two
///   transcripts into one value merges their identity spaces: two
///   transcripts that share a response id count once, and one transcript's
///   `token_usage_record` lines suppress the other's cumulative fallback.
///   Use a fresh accumulator per transcript, and sum the ``totals``.
///
/// ## Why this is not a sum
///
/// Both providers report the same spend more than once, so adding up every
/// usage block in a transcript overstates it. The two shapes of repetition
/// are different and neither is a bug in the provider.
///
/// **Claude Code repeats one response across its content blocks.** An
/// assistant turn that thinks, writes text and calls two tools is written
/// as several JSONL lines, and every one of them carries the same
/// `message.usage`. Measured over real transcripts, summing them overstates
/// total tokens by roughly 1.8x. Deduplicating on the response identity
/// (`requestId` plus `message.id`) is what makes the number mean anything.
/// The copies are not always equal: while a response streams, the early
/// lines carry a placeholder output count, so the largest report for an
/// identity is the finished one and that is the copy kept.
///
/// **Codex reports every response twice, in two record types.** A
/// `token_usage_record` line and an `event_msg` / `token_count` line both
/// carry the same counts at different ordinals. On top of that, the
/// `token_count` event carries `total_token_usage`, which is a running
/// total, beside `last_token_usage`, which is the most recent call.
/// Summing every cumulative report grows quadratically and sails past the
/// context window. So the accumulator uses per-response records once they
/// appear and cumulative events as the fallback before that. A cumulative-
/// only prefix remains as an unattributed baseline when records begin.
///
/// The cumulative fallback is not simply the largest value reported.
/// `total_token_usage` counts from the start of a *thread*, and a rollout
/// holds more than one: a compaction, a `/new`, or a subagent turn starts
/// the count over, and the payload carries no thread id to separate them
/// by. So the count is read as a sequence of monotone runs. Each time the
/// value drops, the run that just ended is banked and a new one starts, and
/// the total is every banked run plus the current one. Taking the maximum
/// instead reports only the largest single thread, which on a long session
/// with several compactions is a fraction of what was spent.
///
/// Unlike ``ClaudeTranscriptParser``, this deliberately counts sidechain
/// (subagent) lines. A subagent's tokens are spent tokens. They are hidden
/// from the conversation view, not from the bill.
public struct ChatUsageAccumulator: Sendable {
    /// The established nested spelling for ``ChatUsageCodexSource``.
    public typealias CodexSource = ChatUsageCodexSource

    /// Number of recent response identities retained for deduplication.
    ///
    /// Both providers repeat identities locally. Four thousand entries leave
    /// ample room for those clusters while bounding a long-lived tailer's
    /// memory use.
    static let recentResponseIdentityLimit = 4_096

    /// Claude's model name for a message it produced without an API call.
    ///
    /// Claude Code writes these for locally generated content, with a usage
    /// block of zeros. Counting them adds a `<synthetic>` row to the model
    /// split and inflates the response count with turns that cost nothing.
    private static let claudeSyntheticModel = "<synthetic>"

    /// The count keys this parser reads out of a Claude usage block.
    private static let claudeCountKeys = [
        "input_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
        "output_tokens",
    ]

    /// The count keys this parser reads out of a Codex usage block.
    private static let codexCountKeys = [
        "input_tokens",
        "cached_input_tokens",
        "cache_write_input_tokens",
        "output_tokens",
    ]

    /// One Claude response's counted usage, and the model it was billed to.
    private struct ClaudeResponse {
        var usage: ChatTokenUsage
        var model: String?
    }

    // Claude accounting keeps the largest report for each recent identity.
    private var claudeCountedResponses: RecentIDMap<String, ClaudeResponse>
    private var claudeResponseCount = 0
    private var claudeUsage = ChatTokenUsage()
    private var claudeUsageByModel: [String: ChatTokenUsage] = [:]

    // Codex per-response accounting, keyed by a bounded response-id window.
    private var codexCountedResponses: RecentIDSet<String>
    private var codexResponseCount = 0
    private var codexRecordUsage = ChatTokenUsage()
    private var codexRecordUsageByModel: [String: ChatTokenUsage] = [:]

    // `banked` holds finished monotone cumulative runs and `current` the run
    // still climbing. They continue updating in record mode so resets remain
    // part of the provisional pre-record baseline.
    private var codexCumulativeBanked = ChatTokenUsage()
    private var codexCumulativeCurrent: ChatTokenUsage?
    private var codexCumulativeBaseline = ChatTokenUsage()
    private var codexRecordUsageSinceTransition = ChatTokenUsage()

    private var duplicateReports = 0
    private var unidentifiedReports = 0
    private var latestCodexModel: String?
    private var contextTokens: Int?
    private var contextWindowTokens: Int?
    private var rateLimit: ChatUsageRateLimit?

    /// Creates an empty accumulator.
    public init() {
        let limit = Self.recentResponseIdentityLimit
        claudeCountedResponses = RecentIDMap(capacity: limit)
        codexCountedResponses = RecentIDSet(capacity: limit)
    }

    /// Which Codex source the current totals came from.
    public private(set) var codexSource: CodexSource = .none

    /// The usage summed so far.
    public var totals: ChatUsageTotals {
        var usage = claudeUsage
        var byModel = claudeUsageByModel
        var responses = claudeResponseCount

        switch codexSource {
        case .none:
            break
        case .usageRecords:
            usage += codexCumulativeBaseline
            usage += codexRecordUsage
            responses = ChatTokenUsage.saturatedSum(responses, codexResponseCount)
            for (model, modelUsage) in codexRecordUsageByModel {
                byModel[model, default: ChatTokenUsage()] += modelUsage
            }
        case .cumulativeEvents:
            // The cumulative total cannot be attributed per response or per
            // model, so it contributes to the overall figure only. Leaving
            // it out of `usageByModel` keeps that split honest.
            usage += codexCumulativeTotal
        }

        // `usageByModel` can sum to less than `usage` for two reasons, and
        // neither is a lost count: the cumulative Codex fallback carries no
        // model at all, and a record that arrives before the first
        // `turn_context` has no model to attribute to yet. `codexSource`
        // distinguishes the first case; the second shows up as a total
        // above the split on an otherwise precise transcript.
        return ChatUsageTotals(
            usage: usage,
            usageByModel: byModel,
            responses: responses,
            duplicateReports: duplicateReports,
            unidentifiedReports: unidentifiedReports,
            contextTokens: contextTokens,
            contextWindowTokens: contextWindowTokens,
            rateLimit: rateLimit
        )
    }

    /// Every banked cumulative run plus the one still climbing.
    private var codexCumulativeTotal: ChatTokenUsage {
        guard let codexCumulativeCurrent else { return codexCumulativeBanked }
        return codexCumulativeBanked + codexCumulativeCurrent
    }

    /// Ingests a run of Claude Code transcript lines.
    ///
    /// - Parameter lines: Raw JSONL lines in transcript order, from one
    ///   transcript.
    public mutating func ingest(claudeLines lines: some Sequence<String>) {
        for line in lines { ingest(claudeLine: line) }
    }

    /// Ingests a run of Codex rollout lines.
    ///
    /// - Parameter lines: Raw JSONL lines in transcript order, from one
    ///   rollout. Feeding a second rollout into the same accumulator merges
    ///   the two identity spaces; see the type's discussion.
    public mutating func ingest(codexLines lines: some Sequence<String>) {
        for line in lines { ingest(codexLine: line) }
    }

    /// Ingests one Claude Code transcript line.
    ///
    /// Malformed lines, and lines without a usage block, are skipped.
    ///
    /// - Parameter line: One raw JSONL line.
    public mutating func ingest(claudeLine line: String) {
        guard let root = TranscriptJSONValue(jsonLine: line),
              let message = root["message"],
              let usageValue = message["usage"],
              usageValue.object != nil
        else { return }

        let model = message["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        // Claude Code writes client-side assistant messages (API errors,
        // interrupts) with model `<synthetic>` and an all-zero usage block.
        // No API call happened, so they are not responses and must not
        // count as one or open a `<synthetic>` bucket in the model split.
        if model == Self.claudeSyntheticModel { return }

        // A usage block with no response id cannot be deduplicated, and
        // counting it risks the 1.8x overstatement this whole type exists
        // to avoid. Skipping it undercounts by one response instead, which
        // is the smaller and more visible error: `unidentifiedReports`
        // shows it happened.
        guard let messageID = message["id"]?.string, !messageID.isEmpty else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }
        // Same for a block with no count key this parser knows: it cannot
        // be read, and counting a zero for it would hide that.
        guard Self.hasRecognizedCount(usageValue, keys: Self.claudeCountKeys) else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }

        // Claude's `input_tokens` already excludes both cache figures, so
        // the three fields map straight across with no arithmetic.
        let usage = ChatTokenUsage(
            freshInputTokens: nonNegative(usageValue["input_tokens"]?.int),
            cacheReadTokens: nonNegative(usageValue["cache_read_input_tokens"]?.int),
            cacheWriteTokens: nonNegative(usageValue["cache_creation_input_tokens"]?.int),
            outputTokens: nonNegative(usageValue["output_tokens"]?.int),
            reasoningOutputTokens: nonNegative(
                usageValue["output_tokens_details"]?["thinking_tokens"]?.int
            )
        )

        // `requestId` is part of the identity on purpose: a retried request
        // reuses the message id, and the retry is a second billed response.
        let key = "\(root["requestId"]?.string ?? "-")|\(messageID)"
        guard let counted = claudeCountedResponses.value(forKey: key) else {
            claudeCountedResponses.setValue(
                ClaudeResponse(usage: usage, model: model),
                forKey: key
            )
            Self.incrementSaturating(&claudeResponseCount)
            claudeUsage += usage
            addToClaudeModel(model, usage)
            return
        }

        // A repeat, which is the normal case. While a response streams, the
        // early lines carry a placeholder output count and the last line
        // carries the finished one, so the largest report wins and a tie
        // keeps the copy already counted.
        Self.incrementSaturating(&duplicateReports)
        guard Self.isLargerClaudeReport(usage, than: counted.usage) else { return }
        claudeCountedResponses.setValue(
            ClaudeResponse(usage: usage, model: model),
            forKey: key
        )
        claudeUsage += Self.difference(usage, counted.usage)
        if counted.model == model {
            addToClaudeModel(model, Self.difference(usage, counted.usage))
        } else {
            // The model changed between two reports of one identity, which
            // should not happen. Move the whole amount instead of a delta so
            // neither row keeps a share of the other's tokens.
            addToClaudeModel(counted.model, Self.difference(ChatTokenUsage(), counted.usage))
            addToClaudeModel(model, usage)
        }
    }

    /// Adds usage to one model's row, when the model is known.
    private mutating func addToClaudeModel(_ model: String?, _ usage: ChatTokenUsage) {
        guard let model else { return }
        claudeUsageByModel[model, default: ChatTokenUsage()] += usage
    }

    /// Ingests one Codex rollout line.
    ///
    /// Malformed lines, and lines that carry no usage, are skipped.
    ///
    /// - Parameter line: One raw JSONL line.
    public mutating func ingest(codexLine line: String) {
        guard let root = TranscriptJSONValue(jsonLine: line),
              let payload = root["payload"],
              payload.object != nil
        else { return }

        switch root["type"]?.string {
        case "turn_context", "session_meta":
            if let model = payload["model"]?.string, !model.isEmpty {
                latestCodexModel = model
            }
        case "token_usage_record":
            ingestCodexUsageRecord(payload)
        case "event_msg" where payload["type"]?.string == "token_count":
            ingestCodexTokenCount(payload)
        default:
            break
        }
    }

    private mutating func ingestCodexUsageRecord(_ payload: TranscriptJSONValue) {
        guard let usageValue = payload["usage"], usageValue.object != nil else { return }
        guard let responseID = payload["response_id"]?.string, !responseID.isEmpty else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }
        // Checked before the source flips: a record whose counts cannot be
        // read must not take over from the cumulative events and report a
        // session that spent nothing.
        guard Self.hasRecognizedCount(usageValue, keys: Self.codexCountKeys) else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }
        guard codexCountedResponses.insert(responseID) else {
            Self.incrementSaturating(&duplicateReports)
            return
        }
        if codexSource != .usageRecords {
            codexCumulativeBaseline = codexCumulativeTotal
            codexRecordUsageSinceTransition = ChatTokenUsage()
        }
        // Records are precise from this point forward. Any cumulative prefix
        // remains as an unattributed baseline and later events reconcile it.
        codexSource = .usageRecords
        Self.incrementSaturating(&codexResponseCount)
        let usage = codexUsage(from: usageValue)
        codexRecordUsage += usage
        codexRecordUsageSinceTransition += usage
        // No model yet means no `turn_context` has been seen, so there is
        // nothing to attribute this to. The tokens still count in the
        // total; only the split loses them.
        if let latestCodexModel {
            codexRecordUsageByModel[latestCodexModel, default: ChatTokenUsage()] += usage
        }
    }

    private mutating func ingestCodexTokenCount(_ payload: TranscriptJSONValue) {
        guard let info = payload["info"], info.object != nil else {
            // A rate-limit-only event still carries useful allowance state.
            readRateLimit(payload["rate_limits"])
            return
        }
        if let window = info["model_context_window"]?.int, window > 0 {
            contextWindowTokens = window
        }
        readCodexOccupancy(info)
        readCodexCumulative(info)
        readRateLimit(payload["rate_limits"])
    }

    /// Reads how full the context window is from the most recent call.
    ///
    /// The window holds the most recent *prompt*, not the session's running
    /// total. `total_token_usage` is cumulative and routinely exceeds the
    /// window, so reading occupancy from it would report a context several
    /// times full. `last_token_usage.total_tokens` is the whole last call,
    /// input and output, and the output is in the window too because it is
    /// the prefix of the next prompt.
    private mutating func readCodexOccupancy(_ info: TranscriptJSONValue) {
        guard let last = info["last_token_usage"], last.object != nil else { return }
        if let total = last["total_tokens"]?.int {
            contextTokens = max(0, total)
            return
        }
        let usage = codexUsage(from: last)
        guard !usage.isEmpty else { return }
        contextTokens = usage.totalTokens
    }

    /// Folds one cumulative report into the monotone-run total.
    ///
    /// In record mode the same stream recomputes the provisional baseline by
    /// removing records counted since the source transition. Continuing to
    /// bank drops is what preserves thread resets after records begin.
    private mutating func readCodexCumulative(_ info: TranscriptJSONValue) {
        guard let cumulative = info["total_token_usage"],
              cumulative.object != nil
        else { return }
        guard Self.hasRecognizedCount(cumulative, keys: Self.codexCountKeys) else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }
        let usage = codexUsage(from: cumulative)
        // A leading zero report says a thread started, not that it spent
        // anything, and flipping the source on it would claim the
        // transcript is accounted for when nothing has been read.
        guard !usage.isEmpty else { return }

        let usingRecords = codexSource == .usageRecords
        defer {
            if usingRecords {
                codexCumulativeBaseline = Self.clampedDifference(
                    codexCumulativeTotal,
                    codexRecordUsageSinceTransition
                )
            } else {
                codexSource = .cumulativeEvents
            }
        }
        guard let current = codexCumulativeCurrent else {
            codexCumulativeCurrent = usage
            return
        }
        if usage.totalTokens > current.totalTokens {
            codexCumulativeCurrent = usage
        } else if usage.totalTokens == current.totalTokens {
            Self.incrementSaturating(&duplicateReports)
        } else {
            // A running total never shrinks, so a smaller value is a new
            // thread counting from zero: bank the run that just ended.
            codexCumulativeBanked += current
            codexCumulativeCurrent = usage
        }
    }

    private mutating func readRateLimit(_ value: TranscriptJSONValue?) {
        guard let value, value.object != nil else { return }
        guard let primary = Self.rateLimitWindow(value["primary"]) else { return }
        rateLimit = ChatUsageRateLimit(
            primary: primary,
            secondary: Self.rateLimitWindow(value["secondary"]),
            spendControlReached: value["spend_control_reached"]?.bool ?? false
        )
    }

    private static func rateLimitWindow(
        _ value: TranscriptJSONValue?
    ) -> ChatUsageRateLimit.Window? {
        guard let value, value.object != nil,
              let usedPercent = value["used_percent"]?.double
        else { return nil }
        var resetsAt: Date?
        if let epoch = value["resets_at"]?.double, epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        }
        return ChatUsageRateLimit.Window(
            usedPercent: usedPercent,
            windowMinutes: value["window_minutes"]?.int,
            resetsAt: resetsAt
        )
    }

    /// Whether a usage object carries at least one count this parser reads.
    ///
    /// A provider that renames every count key, or starts writing them as
    /// strings, would otherwise read as a response that cost zero tokens.
    /// An unreadable block is worth noticing, so the caller counts it in
    /// `unidentifiedReports` instead.
    private static func hasRecognizedCount(
        _ value: TranscriptJSONValue,
        keys: [String]
    ) -> Bool {
        keys.contains { value[$0]?.int != nil }
    }

    /// Converts one Codex usage object into the normalized shape.
    ///
    /// Codex's `input_tokens` is the whole prompt, with `cached_input_tokens`
    /// and `cache_write_input_tokens` as subsets of it, which is the
    /// opposite of Claude's convention. Subtracting them back out is what
    /// makes the two providers comparable. The clamp matters: a future
    /// Codex that reports the cache figures *outside* `input_tokens` would
    /// otherwise produce a negative fresh count, and a zero is a better
    /// wrong answer than a negative one.
    private func codexUsage(from value: TranscriptJSONValue) -> ChatTokenUsage {
        let input = nonNegative(value["input_tokens"]?.int)
        let cacheRead = nonNegative(value["cached_input_tokens"]?.int)
        let cacheWrite = nonNegative(value["cache_write_input_tokens"]?.int)
        let cachedInput = ChatTokenUsage.saturatedSum(cacheRead, cacheWrite)
        return ChatTokenUsage(
            freshInputTokens: input > cachedInput ? input - cachedInput : 0,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: nonNegative(value["output_tokens"]?.int),
            reasoningOutputTokens: nonNegative(value["reasoning_output_tokens"]?.int)
        )
    }

    /// The field-wise difference of two usage values.
    ///
    /// Used to swap one counted report for a larger one without rebuilding
    /// the running sums, so reading ``totals`` stays independent of how
    /// many lines were fed in.
    private static func difference(
        _ lhs: ChatTokenUsage,
        _ rhs: ChatTokenUsage
    ) -> ChatTokenUsage {
        ChatTokenUsage(
            freshInputTokens: lhs.freshInputTokens - rhs.freshInputTokens,
            cacheReadTokens: lhs.cacheReadTokens - rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens - rhs.cacheWriteTokens,
            outputTokens: lhs.outputTokens - rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens - rhs.reasoningOutputTokens
        )
    }

    /// Whether a streamed Claude report is a later, larger version.
    ///
    /// Saturated totals can tie at `Int.max`, so a component-wise increase is
    /// also accepted when no component shrinks.
    private static func isLargerClaudeReport(
        _ candidate: ChatTokenUsage,
        than existing: ChatTokenUsage
    ) -> Bool {
        if candidate.totalTokens != existing.totalTokens {
            return candidate.totalTokens > existing.totalTokens
        }
        let comparisons = [
            (candidate.freshInputTokens, existing.freshInputTokens),
            (candidate.cacheReadTokens, existing.cacheReadTokens),
            (candidate.cacheWriteTokens, existing.cacheWriteTokens),
            (candidate.outputTokens, existing.outputTokens),
            (candidate.reasoningOutputTokens, existing.reasoningOutputTokens),
        ]
        return comparisons.allSatisfy { $0.0 >= $0.1 }
            && comparisons.contains { $0.0 > $0.1 }
    }

    /// Field-wise subtraction clamped at zero for cumulative reconciliation.
    private static func clampedDifference(
        _ lhs: ChatTokenUsage,
        _ rhs: ChatTokenUsage
    ) -> ChatTokenUsage {
        ChatTokenUsage(
            freshInputTokens: clampedDifference(lhs.freshInputTokens, rhs.freshInputTokens),
            cacheReadTokens: clampedDifference(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: clampedDifference(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            outputTokens: clampedDifference(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: clampedDifference(
                lhs.reasoningOutputTokens,
                rhs.reasoningOutputTokens
            )
        )
    }

    private static func clampedDifference(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > rhs ? lhs - rhs : 0
    }

    private static func incrementSaturating(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }

    private func nonNegative(_ value: Int?) -> Int {
        max(0, value ?? 0)
    }
}
