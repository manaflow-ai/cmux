import Foundation

/// Accumulates normalized token usage from agent transcript JSONL lines.
///
/// Feed lines in transcript order, then read ``totals``. The accumulator is
/// incremental so a caller tailing a growing transcript can keep one value
/// across reads, the same way ``ChatTranscriptParseState`` works for
/// message parsing.
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
///
/// **Codex reports every response twice, in two record types.** A
/// `token_usage_record` line and an `event_msg` / `token_count` line both
/// carry the same counts at different ordinals. On top of that, the
/// `token_count` event carries `total_token_usage`, which is *cumulative
/// for the session*, beside `last_token_usage`, which is the most recent
/// call. Summing the cumulative field grows quadratically and sails past
/// the context window; in a normal session its final value is many times
/// the true total. So the accumulator picks one source per transcript:
/// `token_usage_record` when the file has any, otherwise the maximum
/// cumulative value the events reported, which needs no summing because it
/// is already a running total.
///
/// Unlike ``ClaudeTranscriptParser``, this deliberately counts sidechain
/// (subagent) lines. A subagent's tokens are spent tokens. They are hidden
/// from the conversation view, not from the bill.
public struct ChatUsageAccumulator: Sendable {
    /// Which Codex record type a transcript's accounting came from.
    ///
    /// Recorded so a caller can tell a precise per-response total from the
    /// coarser cumulative fallback, which cannot be split by model.
    public enum CodexSource: Sendable, Equatable {
        /// No Codex usage seen yet.
        case none
        /// Per-response `token_usage_record` lines, the precise source.
        case usageRecords
        /// The cumulative `total_token_usage` from `token_count` events,
        /// used when the transcript predates `token_usage_record`.
        case cumulativeEvents
    }

    // Claude accounting, keyed by response identity.
    private var claudeCountedResponses: Set<String> = []
    private var claudeUsage = ChatTokenUsage()
    private var claudeUsageByModel: [String: ChatTokenUsage] = [:]

    // Codex per-response accounting, keyed by response id.
    private var codexCountedResponses: Set<String> = []
    private var codexRecordUsage = ChatTokenUsage()
    private var codexRecordUsageByModel: [String: ChatTokenUsage] = [:]

    // Codex cumulative fallback, used only when no record lines appear.
    private var codexCumulativeUsage: ChatTokenUsage?

    private var duplicateReports = 0
    private var unidentifiedReports = 0
    private var latestCodexModel: String?
    private var contextTokens: Int?
    private var contextWindowTokens: Int?
    private var rateLimit: ChatUsageRateLimit?

    /// Creates an empty accumulator.
    public init() {}

    /// Which Codex source the current totals came from.
    public private(set) var codexSource: CodexSource = .none

    /// The usage summed so far.
    public var totals: ChatUsageTotals {
        var usage = claudeUsage
        var byModel = claudeUsageByModel
        var responses = claudeCountedResponses.count

        switch codexSource {
        case .none:
            break
        case .usageRecords:
            usage += codexRecordUsage
            responses += codexCountedResponses.count
            for (model, modelUsage) in codexRecordUsageByModel {
                byModel[model, default: ChatTokenUsage()] += modelUsage
            }
        case .cumulativeEvents:
            // The cumulative total cannot be attributed per response or per
            // model, so it contributes to the overall figure only. Leaving
            // it out of `usageByModel` keeps that split honest: a caller
            // summing the split will not match the total, and `codexSource`
            // says why.
            if let codexCumulativeUsage {
                usage += codexCumulativeUsage
            }
        }

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

    /// Ingests a run of Claude Code transcript lines.
    ///
    /// - Parameter lines: Raw JSONL lines in transcript order.
    public mutating func ingest(claudeLines lines: some Sequence<String>) {
        for line in lines { ingest(claudeLine: line) }
    }

    /// Ingests a run of Codex rollout lines.
    ///
    /// - Parameter lines: Raw JSONL lines in transcript order.
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

        // A usage block with no response id cannot be deduplicated, and
        // counting it risks the 1.8x overstatement this whole type exists
        // to avoid. Skipping it undercounts by one response instead, which
        // is the smaller and more visible error: `unidentifiedReports`
        // shows it happened.
        guard let messageID = message["id"]?.string, !messageID.isEmpty else {
            unidentifiedReports += 1
            return
        }
        let key = "\(root["requestId"]?.string ?? "-")|\(messageID)"
        guard claudeCountedResponses.insert(key).inserted else {
            duplicateReports += 1
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
        claudeUsage += usage
        if let model = message["model"]?.string, !model.isEmpty {
            claudeUsageByModel[model, default: ChatTokenUsage()] += usage
        }
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
            unidentifiedReports += 1
            return
        }
        guard codexCountedResponses.insert(responseID).inserted else {
            duplicateReports += 1
            return
        }
        // Records are the precise source, so they take over from any
        // cumulative figure already read from events.
        codexSource = .usageRecords
        let usage = codexUsage(from: usageValue)
        codexRecordUsage += usage
        if let model = latestCodexModel {
            codexRecordUsageByModel[model, default: ChatTokenUsage()] += usage
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
        // The context window holds the most recent *prompt*, not the
        // session's running total. `total_token_usage` is cumulative and
        // routinely exceeds the window, so reading occupancy from it would
        // report a context that is several times full.
        if let lastInput = info["last_token_usage"]?["input_tokens"]?.int {
            contextTokens = max(0, lastInput)
        }
        // Cumulative, so the newest value is the session total. Only used
        // when the transcript has no per-response records.
        if codexSource != .usageRecords, let cumulative = info["total_token_usage"] {
            let usage = codexUsage(from: cumulative)
            if !usage.isEmpty {
                if let existing = codexCumulativeUsage, existing.totalTokens >= usage.totalTokens {
                    // Out-of-order or repeated event: a running total never
                    // shrinks, so the larger value is the current one.
                    duplicateReports += 1
                } else {
                    codexCumulativeUsage = usage
                }
                codexSource = .cumulativeEvents
            }
        }
        readRateLimit(payload["rate_limits"])
    }

    private mutating func readRateLimit(_ value: TranscriptJSONValue?) {
        guard let primary = value?["primary"], primary.object != nil,
              let usedPercent = primary["used_percent"]?.double
        else { return }
        var resetsAt: Date?
        if let epoch = primary["resets_at"]?.double, epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        }
        rateLimit = ChatUsageRateLimit(
            usedPercent: usedPercent,
            windowMinutes: primary["window_minutes"]?.int,
            resetsAt: resetsAt
        )
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
        return ChatTokenUsage(
            freshInputTokens: max(0, input - cacheRead - cacheWrite),
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: nonNegative(value["output_tokens"]?.int),
            reasoningOutputTokens: nonNegative(value["reasoning_output_tokens"]?.int)
        )
    }

    private func nonNegative(_ value: Int?) -> Int {
        max(0, value ?? 0)
    }
}
