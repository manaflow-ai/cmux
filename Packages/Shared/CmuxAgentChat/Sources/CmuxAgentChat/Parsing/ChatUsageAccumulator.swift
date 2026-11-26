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
/// appear and cumulative events only as the fallback before that. A preceding
/// cumulative snapshot from the same user rollout remains as a pre-record
/// prefix, while session metadata that identifies inherited subagent history
/// removes the parent baseline and preserves only proven child growth.
///
/// The cumulative fallback is split only at an explicit thread/session
/// identity change or provider zero-reset. A `compacted` event changes visible
/// context but does not reset Codex's lifetime usage counter. A numeric
/// drop alone cannot prove a new thread, while a new thread can start above
/// the old total. An unmarked drop therefore remains a latest-value fallback
/// and sets ``ChatUsageTotals/cumulativeUsageIsAmbiguous`` instead of silently
/// guessing a boundary from magnitude.
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
    static let retainedTranscriptStringByteLimit = 1_024

    /// Maximum distinct model rows retained by one long-lived tailer.
    static let usageModelBucketLimit = 64
    static let usageModelNameByteLimit = 256
    private static let overflowModelBucket = "<other models>"

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
        var modelBucket: String?
    }

    // Claude accounting keeps the largest report for each recent identity.
    private var claudeCountedResponses: RecentIDMap<String, ClaudeResponse>
    private var claudeResponseCount = 0
    private var claudeUsage = ChatTokenUsage()
    private var claudeUsageByModel: [String: ChatTokenUsage] = [:]

    // Codex per-response accounting, keyed by a bounded response-id window.
    private var codexCountedResponses: RecentIDSet<String>
    // Delayed records resolve through bounded identity maps rather than the
    // most recently observed turn, which may belong to another model.
    private var codexModelByTurn: RecentIDMap<String, String>
    private var codexModelByThread: RecentIDMap<String, String>
    private var codexResponseCount = 0
    private var codexRecordUsage = ChatTokenUsage()
    private var codexRecordPrefixUsage = ChatTokenUsage()
    private var codexRecordUsageByModel: [String: ChatTokenUsage] = [:]

    // `banked` holds finished monotone cumulative runs and `current` the run
    // still climbing. Once response records appear, records own all usage.
    private var codexCumulativeBanked = ChatTokenUsage()
    private var codexCumulativeCurrent: ChatTokenUsage?
    private var codexInheritedCumulativeBaseline: ChatTokenUsage?
    private var codexCumulativeReplaceableTail: ChatTokenUsage?
    private var cumulativeUsageIsAmbiguous = false

    private var duplicateReports = 0
    private var unidentifiedReports = 0
    private var codexSessionModel: String?
    private var codexSessionID: String?
    private var codexThreadID: String?
    private var codexTranscriptInheritsHistory = false
    private var contextWindowTokens: Int?
    private var rateLimit: ChatUsageRateLimit?

    /// Creates an empty accumulator.
    public init() {
        let limit = Self.recentResponseIdentityLimit
        claudeCountedResponses = RecentIDMap(capacity: limit)
        codexCountedResponses = RecentIDSet(capacity: limit)
        codexModelByTurn = RecentIDMap(capacity: limit)
        codexModelByThread = RecentIDMap(capacity: limit)
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
            usage += codexRecordPrefixUsage + codexRecordUsage
            responses = ChatTokenUsage.saturatedSum(responses, codexResponseCount)
            for (model, modelUsage) in codexRecordUsageByModel {
                byModel[model, default: ChatTokenUsage()] += modelUsage
            }
            byModel = Self.boundedUsageByModel(byModel)
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
            cumulativeUsageIsAmbiguous: cumulativeUsageIsAmbiguous,
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

        let rawModel = message["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        // Claude Code writes client-side assistant messages (API errors,
        // interrupts) with model `<synthetic>` and an all-zero usage block.
        // No API call happened, so they are not responses and must not
        // count as one or open a `<synthetic>` bucket in the model split.
        if rawModel == Self.claudeSyntheticModel { return }
        let model = Self.retainedModel(rawModel)

        // A usage block with no response id cannot be deduplicated, and
        // counting it risks the 1.8x overstatement this whole type exists
        // to avoid. Skipping it undercounts by one response instead, which
        // is the smaller and more visible error: `unidentifiedReports`
        // shows it happened.
        guard let messageID = Self.retainedIdentity(message["id"]?.string) else {
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
        let requestID = root["requestId"]?.string ?? "-"
        guard let key = Self.retainedIdentity("\(requestID)|\(messageID)") else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }
        guard let counted = claudeCountedResponses.value(forKey: key) else {
            let modelBucket = addToClaudeModel(model, usage)
            claudeCountedResponses.setValue(
                ClaudeResponse(usage: usage, model: model, modelBucket: modelBucket),
                forKey: key
            )
            Self.incrementSaturating(&claudeResponseCount)
            claudeUsage += usage
            return
        }

        // A repeat, which is the normal case. While a response streams, the
        // early lines carry a placeholder output count and the last line
        // carries the finished one, so the largest report wins and a tie
        // keeps the copy already counted.
        Self.incrementSaturating(&duplicateReports)
        guard Self.isLargerClaudeReport(usage, than: counted.usage) else { return }
        claudeUsage += Self.difference(usage, counted.usage)
        let modelBucket: String?
        if counted.model == model {
            addToClaudeModelBucket(counted.modelBucket, Self.difference(usage, counted.usage))
            modelBucket = counted.modelBucket
        } else {
            // The model changed between two reports of one identity, which
            // should not happen. Move the whole amount instead of a delta so
            // neither row keeps a share of the other's tokens.
            removeFromClaudeModelBucket(counted.modelBucket, counted.usage)
            modelBucket = addToClaudeModel(model, usage)
        }
        claudeCountedResponses.setValue(
            ClaudeResponse(usage: usage, model: model, modelBucket: modelBucket),
            forKey: key
        )
    }

    /// Adds usage to one model's row, when the model is known.
    @discardableResult
    private mutating func addToClaudeModel(
        _ model: String?,
        _ usage: ChatTokenUsage
    ) -> String? {
        guard let model else { return nil }
        let bucket = Self.usageModelBucket(for: model, in: claudeUsageByModel)
        addToClaudeModelBucket(bucket, usage)
        return bucket
    }

    private mutating func addToClaudeModelBucket(
        _ bucket: String?,
        _ usage: ChatTokenUsage
    ) {
        guard let bucket else { return }
        claudeUsageByModel[bucket, default: ChatTokenUsage()] += usage
    }

    private mutating func removeFromClaudeModelBucket(
        _ bucket: String?,
        _ usage: ChatTokenUsage
    ) {
        guard let bucket, let counted = claudeUsageByModel[bucket] else { return }
        let remainder = Self.difference(counted, usage)
        if remainder.isEmpty, bucket != Self.overflowModelBucket {
            claudeUsageByModel.removeValue(forKey: bucket)
        } else {
            claudeUsageByModel[bucket] = remainder
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
        case "turn_context":
            ingestCodexTurnContext(payload)
        case "session_meta":
            ingestCodexSessionMetadata(payload)
        case "token_usage_record":
            ingestCodexUsageRecord(payload)
        case "event_msg" where payload["type"]?.string == "token_count":
            ingestCodexTokenCount(payload)
        default:
            break
        }
    }

    private mutating func ingestCodexTurnContext(_ payload: TranscriptJSONValue) {
        observeCodexThreadID(payload["thread_id"]?.string)
        guard let model = Self.retainedModel(payload["model"]?.string) else { return }
        if let turnID = Self.retainedIdentity(payload["turn_id"]?.string) {
            codexModelByTurn.setValue(model, forKey: turnID)
        }
        if let threadID = Self.retainedIdentity(payload["thread_id"]?.string) {
            codexModelByThread.setValue(model, forKey: threadID)
        }
    }

    private mutating func ingestCodexSessionMetadata(_ payload: TranscriptJSONValue) {
        let threadSource = (
            payload["thread_source"]?.string ?? payload["threadSource"]?.string
        )?.lowercased()
        let source = payload["source"]?.string?.lowercased()
        let internalSource = payload["source"]?["internal"]?.string?.lowercased()
        let inheritsHistory = threadSource == "subagent"
            || threadSource == "memory_consolidation"
            || threadSource == "memoryconsolidation"
            || source == "subagent"
            || source == "memory_consolidation"
            || source == "memoryconsolidation"
            || payload["source"]?["subagent"]?.object != nil
            || internalSource == "memory_consolidation"
            || internalSource == "memoryconsolidation"
        if inheritsHistory, !codexTranscriptInheritsHistory {
            codexTranscriptInheritsHistory = true
            codexCumulativeBanked = ChatTokenUsage()
            codexInheritedCumulativeBaseline = codexCumulativeCurrent
            codexCumulativeCurrent = nil
            codexCumulativeReplaceableTail = nil
        }
        observeCodexSessionID(payload["id"]?.string)
        observeCodexThreadID(payload["thread_id"]?.string)
        guard let model = Self.retainedModel(payload["model"]?.string) else { return }
        codexSessionModel = model
        if let threadID = Self.retainedIdentity(payload["thread_id"]?.string) {
            codexModelByThread.setValue(model, forKey: threadID)
        }
    }

    private mutating func ingestCodexUsageRecord(_ payload: TranscriptJSONValue) {
        guard let usageValue = payload["usage"], usageValue.object != nil else { return }
        guard let responseID = Self.retainedIdentity(payload["response_id"]?.string) else {
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
        let usage = codexUsage(from: usageValue)
        // Records are precise from this point forward. Preserve a cumulative
        // prefix written before record support appeared. In an inherited
        // rollout, cumulative accounting has already removed the parent
        // baseline. The one exception is a latest cumulative tail that is the
        // same response as this first precise record: replace that estimate
        // instead of counting the response twice.
        if codexSource != .usageRecords {
            var prefix = codexCumulativeTotal
            if codexTranscriptInheritsHistory,
               let tail = codexCumulativeReplaceableTail,
               tail == usage,
               let withoutTail = Self.subtract(tail, from: prefix)
            {
                prefix = withoutTail
            }
            codexRecordPrefixUsage = prefix
            // A precise record can replace the latest cumulative tail, but it
            // cannot resolve an earlier component reset. Keep that ambiguity
            // even when tail replacement leaves no numeric prefix.
        }
        codexSource = .usageRecords
        codexCumulativeReplaceableTail = nil
        Self.incrementSaturating(&codexResponseCount)
        codexRecordUsage += usage
        // Resolve the record against its own identity. A later turn context
        // must not steal a delayed record from an earlier turn. Only an
        // explicitly declared session model is a safe identity-free fallback.
        if let model = codexModel(for: payload) {
            let bucket = Self.usageModelBucket(for: model, in: codexRecordUsageByModel)
            codexRecordUsageByModel[bucket, default: ChatTokenUsage()] += usage
        }
    }

    private static func usageModelBucket(
        for model: String,
        in usageByModel: [String: ChatTokenUsage]
    ) -> String {
        guard model.utf8.count <= usageModelNameByteLimit else { return overflowModelBucket }
        if usageByModel[model] != nil { return model }
        // Reserve the final row for every later or oversized provider value.
        return usageByModel.count < usageModelBucketLimit - 1 ? model : overflowModelBucket
    }

    private static func boundedUsageByModel(
        _ usageByModel: [String: ChatTokenUsage]
    ) -> [String: ChatTokenUsage] {
        guard usageByModel.count > usageModelBucketLimit else { return usageByModel }
        let retainedModels = usageByModel.keys
            .filter { $0 != overflowModelBucket }
            .sorted()
            .prefix(usageModelBucketLimit - 1)
        let retained = Set(retainedModels)
        var bounded = Dictionary(uniqueKeysWithValues: retainedModels.compactMap { model in
            usageByModel[model].map { (model, $0) }
        })
        var overflow = usageByModel[overflowModelBucket] ?? ChatTokenUsage()
        for (model, usage) in usageByModel where model != overflowModelBucket && !retained.contains(model) {
            overflow += usage
        }
        if !overflow.isEmpty {
            bounded[overflowModelBucket] = overflow
        }
        return bounded
    }

    private func codexModel(for payload: TranscriptJSONValue) -> String? {
        if let rawTurnID = payload["turn_id"]?.string, !rawTurnID.isEmpty {
            // A present turn identity is authoritative. If its bounded entry
            // is unknown or expired, every fallback could silently charge the
            // response to another turn's model.
            guard let turnID = Self.retainedIdentity(rawTurnID) else { return nil }
            return codexModelByTurn.value(forKey: turnID)
        }
        if let rawThreadID = payload["thread_id"]?.string, !rawThreadID.isEmpty {
            guard let threadID = Self.retainedIdentity(rawThreadID) else { return nil }
            return codexModelByThread.value(forKey: threadID) ?? codexSessionModel
        }
        return codexSessionModel
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
        readCodexCumulative(info)
        readRateLimit(payload["rate_limits"])
    }

    private mutating func observeCodexSessionID(_ candidate: String?) {
        guard let candidate = Self.retainedIdentity(candidate) else { return }
        if let codexSessionID, codexSessionID != candidate {
            beginCodexCumulativeRun()
            codexSessionModel = nil
        }
        codexSessionID = candidate
    }

    private mutating func observeCodexThreadID(_ candidate: String?) {
        guard let candidate = Self.retainedIdentity(candidate) else { return }
        if let codexThreadID, codexThreadID != candidate {
            beginCodexCumulativeRun()
        }
        codexThreadID = candidate
    }

    /// Banks a cumulative run at a provider-declared thread/reset boundary.
    private mutating func beginCodexCumulativeRun() {
        guard codexSource != .usageRecords else { return }
        if let codexCumulativeCurrent {
            codexCumulativeBanked += codexCumulativeCurrent
        }
        self.codexCumulativeCurrent = nil
        codexInheritedCumulativeBaseline = nil
        codexCumulativeReplaceableTail = nil
    }

    /// Folds one fallback cumulative report into the monotone-run total.
    ///
    /// Once response records appear they are authoritative. A cumulative
    /// snapshot carries no response identities, so it cannot prove which
    /// records it reflects and must not revise the frozen prefix.
    private mutating func readCodexCumulative(_ info: TranscriptJSONValue) {
        guard let cumulative = info["total_token_usage"],
              cumulative.object != nil
        else { return }
        guard Self.hasRecognizedCount(cumulative, keys: Self.codexCountKeys) else {
            Self.incrementSaturating(&unidentifiedReports)
            return
        }
        guard codexSource != .usageRecords else { return }
        let usage = codexUsage(from: cumulative)
        if codexTranscriptInheritsHistory {
            let lastUsage: ChatTokenUsage?
            if let last = info["last_token_usage"],
               last.object != nil,
               Self.hasRecognizedCount(last, keys: Self.codexCountKeys)
            {
                lastUsage = codexUsage(from: last)
            } else {
                lastUsage = nil
            }
            readInheritedCodexCumulative(usage, lastUsage: lastUsage)
            return
        }
        if usage.isEmpty {
            // Zero is a reset delimiter only after a run exists. A leading
            // zero must not claim that cumulative accounting is active.
            guard let current = codexCumulativeCurrent else { return }
            codexCumulativeBanked += current
            codexCumulativeCurrent = nil
            return
        }
        codexSource = .cumulativeEvents
        guard let current = codexCumulativeCurrent else {
            codexCumulativeCurrent = usage
            return
        }
        if usage == current {
            Self.incrementSaturating(&duplicateReports)
        } else if usage.totalTokens > current.totalTokens,
                  Self.isComponentwiseNondecreasing(usage, from: current)
        {
            codexCumulativeCurrent = usage
        } else {
            // Without a structured boundary this could be either a provider
            // correction or a new thread. Preserve the latest snapshot and
            // make the uncertainty visible instead of guessing from size.
            cumulativeUsageIsAmbiguous = true
            codexCumulativeCurrent = usage
        }
    }

    /// Counts only growth after an inherited parent-thread snapshot.
    private mutating func readInheritedCodexCumulative(
        _ usage: ChatTokenUsage,
        lastUsage: ChatTokenUsage?
    ) {
        codexSource = .cumulativeEvents
        if usage.isEmpty {
            if let current = codexCumulativeCurrent {
                codexCumulativeBanked += current
            }
            codexCumulativeCurrent = nil
            // Unlike the inherited opening snapshot, an explicit zero is a
            // known baseline. The next run belongs wholly to this transcript.
            codexInheritedCumulativeBaseline = ChatTokenUsage()
            codexCumulativeReplaceableTail = nil
            return
        }
        guard let baseline = codexInheritedCumulativeBaseline else {
            if let lastUsage,
               !lastUsage.isEmpty,
               let baseline = Self.subtract(lastUsage, from: usage)
            {
                // Without a pre-response snapshot, the cumulative total
                // already includes the child's first response. The matching
                // `last_token_usage` is the only proven child portion.
                codexInheritedCumulativeBaseline = baseline
                codexCumulativeCurrent = lastUsage
                codexCumulativeReplaceableTail = lastUsage
            } else {
                codexInheritedCumulativeBaseline = usage
                codexCumulativeCurrent = nil
                codexCumulativeReplaceableTail = nil
            }
            return
        }
        guard usage.freshInputTokens >= baseline.freshInputTokens,
              usage.cacheReadTokens >= baseline.cacheReadTokens,
              usage.cacheWriteTokens >= baseline.cacheWriteTokens,
              usage.outputTokens >= baseline.outputTokens,
              usage.reasoningOutputTokens >= baseline.reasoningOutputTokens
        else {
            cumulativeUsageIsAmbiguous = true
            if let current = codexCumulativeCurrent {
                codexCumulativeBanked += current
            }
            codexCumulativeCurrent = nil
            codexInheritedCumulativeBaseline = usage
            codexCumulativeReplaceableTail = nil
            return
        }
        let delta = Self.difference(usage, baseline)
        let replaceableTail: ChatTokenUsage?
        if let lastUsage,
           !lastUsage.isEmpty,
           Self.subtract(lastUsage, from: delta) != nil
        {
            replaceableTail = lastUsage
        } else {
            replaceableTail = nil
        }
        guard let current = codexCumulativeCurrent else {
            codexCumulativeCurrent = delta
            codexCumulativeReplaceableTail = replaceableTail
            return
        }
        if delta.totalTokens > current.totalTokens,
           Self.isComponentwiseNondecreasing(delta, from: current)
        {
            codexCumulativeCurrent = delta
            codexCumulativeReplaceableTail = replaceableTail
        } else if delta == current {
            Self.incrementSaturating(&duplicateReports)
            // A duplicate snapshot without a last-usage block carries no new
            // evidence about which cumulative tail a later record replaces.
            // Preserve the proven tail until a nonempty replacement appears.
            if let replaceableTail {
                codexCumulativeReplaceableTail = replaceableTail
            }
        } else {
            cumulativeUsageIsAmbiguous = true
            codexCumulativeCurrent = delta
            codexCumulativeReplaceableTail = replaceableTail
        }
    }

    private mutating func readRateLimit(_ value: TranscriptJSONValue?) {
        guard let value, value.object != nil else { return }
        let primary = Self.rateLimitWindow(value["primary"])
        let secondary = Self.rateLimitWindow(value["secondary"])
        let spendControlReached = value["spend_control_reached"]?.bool
        guard primary != nil || secondary != nil || spendControlReached != nil else { return }
        rateLimit = ChatUsageRateLimit(
            primary: primary,
            secondary: secondary,
            spendControlReached: spendControlReached
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

    /// Subtracts a usage value only when every component is present.
    private static func subtract(
        _ value: ChatTokenUsage,
        from total: ChatTokenUsage
    ) -> ChatTokenUsage? {
        guard total.freshInputTokens >= value.freshInputTokens,
              total.cacheReadTokens >= value.cacheReadTokens,
              total.cacheWriteTokens >= value.cacheWriteTokens,
              total.outputTokens >= value.outputTokens,
              total.reasoningOutputTokens >= value.reasoningOutputTokens
        else { return nil }
        return difference(total, value)
    }

    /// Whether every cumulative component is at least its prior value.
    ///
    /// A larger aggregate is not enough to establish a monotone provider
    /// counter: one component can reset while another grows past it. Treat
    /// that shape as an ambiguous correction or unmarked run boundary.
    private static func isComponentwiseNondecreasing(
        _ candidate: ChatTokenUsage,
        from previous: ChatTokenUsage
    ) -> Bool {
        candidate.freshInputTokens >= previous.freshInputTokens
            && candidate.cacheReadTokens >= previous.cacheReadTokens
            && candidate.cacheWriteTokens >= previous.cacheWriteTokens
            && candidate.outputTokens >= previous.outputTokens
            && candidate.reasoningOutputTokens >= previous.reasoningOutputTokens
    }

    /// Returns a provider identity only while its retained UTF-8 storage is bounded.
    private static func retainedIdentity(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= retainedTranscriptStringByteLimit
        else { return nil }
        return value
    }

    /// Maps oversized provider model labels to the shared bounded row.
    private static func retainedModel(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.utf8.count <= usageModelNameByteLimit ? value : overflowModelBucket
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

    private static func incrementSaturating(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }

    private func nonNegative(_ value: Int?) -> Int {
        max(0, value ?? 0)
    }
}
