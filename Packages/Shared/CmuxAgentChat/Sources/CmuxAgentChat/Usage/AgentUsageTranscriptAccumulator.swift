import Foundation

/// Folds transcript JSONL lines, in order, into running usage totals for one
/// transcript file.
///
/// The accumulator is incremental: feed it each complete line exactly once
/// (``ingest(line:)``), then read ``snapshot()`` or ``cost()`` at any point.
/// Lines that carry no usage are rejected by a cheap byte search before any
/// JSON parsing.
///
/// - Claude Code writes one `assistant` line per content block, repeating
///   the same `message.id` and `message.usage` (the last line carries the
///   final output count). Each message id is priced from the last line seen
///   for it, even when lines of different ids interleave. Context is the
///   prompt size of the latest main-chain request: `input_tokens +
///   cache_creation_input_tokens + cache_read_input_tokens`. Sidechain
///   (subagent) lines count toward cost but not the context or model.
/// - Codex `event_msg` `token_count` lines carry the latest request
///   (`info.last_token_usage`) and the window (`info.model_context_window`);
///   the latest event wins. Context excludes reasoning output tokens, which
///   Codex does not keep in the window. The model comes from `turn_context`.
///   Codex sessions are not priced.
public struct AgentUsageTranscriptAccumulator: Sendable {
    /// Which transcript format this accumulator parses.
    public let source: AgentUsageSource

    private let catalog: AgentModelCatalog
    private var modelID: String?
    private var contextTokens: Int?
    private var contextWindow: Int?

    // Claude cost bookkeeping, per message id.
    private var messageCosts: [String: Double?] = [:]
    private var pricedTotal: Double = 0
    private var unpricedMessages = 0
    private var anonymousMessages = 0
    private var latestMainMessageID: String?
    private var seenMainMessageIDs: Set<String> = []
    private var historyIncomplete = false
    private var droppedLines = false

    /// Creates an empty accumulator.
    ///
    /// - Parameters:
    ///   - source: The transcript format.
    ///   - catalog: Model table used to price Claude messages (a session can
    ///     switch models mid-way, so each message is priced by its own model).
    public init(source: AgentUsageSource, catalog: AgentModelCatalog = AgentModelCatalog()) {
        self.source = source
        self.catalog = catalog
    }

    private static let claudeUsageMarker = Data(#""usage""#.utf8)
    private static let codexTokenCountMarker = Data(#""token_count""#.utf8)
    private static let codexTurnContextMarker = Data(#""turn_context""#.utf8)

    /// Folds one complete JSONL line (without its trailing newline).
    ///
    /// - Parameter line: The raw line bytes (a slice is fine; it is not
    ///   copied). Malformed or irrelevant lines are ignored.
    public mutating func ingest(line: Data) {
        switch source {
        case .claude:
            guard line.range(of: Self.claudeUsageMarker) != nil else { return }
            ingestClaude(line: line)
        case .codex:
            guard line.range(of: Self.codexTokenCountMarker) != nil
                || line.range(of: Self.codexTurnContextMarker) != nil else { return }
            ingestCodex(line: line)
        }
    }

    /// Convenience for tests and callers holding text.
    ///
    /// - Parameter line: One JSONL line.
    public mutating func ingest(line: String) {
        ingest(line: Data(line.utf8))
    }

    /// Records that reading started mid-file (the head was skipped to bound
    /// the work), so the total cost is unknown. Model and context still
    /// come from the lines that were read.
    public mutating func markHistoryIncomplete() {
        historyIncomplete = true
    }

    /// Records that a line was skipped (too large to buffer), so the cost is
    /// only a lower bound.
    public mutating func markLineDropped() {
        droppedLines = true
    }

    /// The estimated cost of every line read so far, or `nil` when it is
    /// unknowable (Codex, or the head of the file was skipped). Messages of
    /// unknown models make the result a lower bound rather than hiding it.
    public func cost() -> AgentUsageCost? {
        guard source == .claude, !historyIncomplete else { return nil }
        return AgentUsageCost(
            usd: pricedTotal,
            isLowerBound: unpricedMessages > 0 || droppedLines,
            hasPricedUsage: messageCosts.count > unpricedMessages
        )
    }

    /// The usage summary so far, or `nil` before any main-thread model is
    /// known.
    ///
    /// - Returns: A snapshot combining model, context, and estimated cost.
    public func snapshot() -> AgentUsageSnapshot? {
        guard let modelID,
              let info = catalog.info(forModelID: modelID, reportedContextWindow: contextWindow) else {
            return nil
        }
        let tokens = contextTokens ?? 0
        var window = info.contextWindow
        // A Claude request larger than the table's window proves a 1M window
        // (for example a `[1m]` session whose model id carries no suffix).
        if source == .claude, let current = window, tokens > current {
            window = AgentModelCatalog.oneMillionContextWindow
        }
        return AgentUsageSnapshot(
            modelID: modelID,
            modelDisplayName: info.displayName,
            contextTokens: tokens,
            contextWindow: window,
            estimatedCost: cost()?.displayable
        )
    }

    // MARK: Claude

    private mutating func ingestClaude(line: Data) {
        guard let object = Self.jsonObject(line),
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let model = (message["model"] as? String).flatMap { Self.meaningfulModelID($0) }
        let counts = Self.claudeCounts(usage)
        let isSidechain = object["isSidechain"] as? Bool ?? false
        let messageID: String
        if let id = message["id"] as? String, !id.isEmpty {
            messageID = id
        } else {
            anonymousMessages += 1
            messageID = "\u{0}anonymous-\(anonymousMessages)"
        }
        if counts != .zero {
            let newCost = price(counts, modelID: model ?? modelID)
            if let previous = messageCosts[messageID] {
                if let previous { pricedTotal -= previous } else { unpricedMessages -= 1 }
            }
            messageCosts[messageID] = .some(newCost)
            if let newCost { pricedTotal += newCost } else { unpricedMessages += 1 }
        }

        guard !isSidechain else { return }
        // A late line of an older message must not roll the context back.
        let isNewMessage = seenMainMessageIDs.insert(messageID).inserted
        guard isNewMessage || messageID == latestMainMessageID else { return }
        latestMainMessageID = messageID
        if let model { modelID = model }
        if counts.totalInput > 0 { contextTokens = counts.totalInput }
    }

    private func price(_ counts: AgentUsageTokenCounts, modelID: String?) -> Double? {
        guard let modelID, let pricing = catalog.info(forModelID: modelID)?.pricing else { return nil }
        return pricing.estimatedCostUSD(for: counts)
    }

    private static func claudeCounts(_ usage: [String: Any]) -> AgentUsageTokenCounts {
        let cacheCreation = int(usage["cache_creation_input_tokens"])
        var write5m = cacheCreation
        var write1h = 0
        if let split = usage["cache_creation"] as? [String: Any] {
            let fiveMinute = int(split["ephemeral_5m_input_tokens"])
            let oneHour = int(split["ephemeral_1h_input_tokens"])
            if fiveMinute + oneHour > 0 {
                write5m = fiveMinute
                write1h = oneHour
            }
        }
        return AgentUsageTokenCounts(
            uncachedInput: int(usage["input_tokens"]),
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            cacheRead: int(usage["cache_read_input_tokens"]),
            output: int(usage["output_tokens"])
        )
    }

    // MARK: Codex

    private mutating func ingestCodex(line: Data) {
        guard let object = Self.jsonObject(line),
              let payload = object["payload"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "turn_context":
            if let model = (payload["model"] as? String).flatMap({ Self.meaningfulModelID($0) }) {
                modelID = model
            }
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { return }
            if let last = info["last_token_usage"] as? [String: Any] {
                let total = Self.int(last["total_tokens"])
                let all = total > 0 ? total : Self.int(last["input_tokens"]) + Self.int(last["output_tokens"])
                contextTokens = max(0, all - Self.int(last["reasoning_output_tokens"]))
            }
            let window = Self.int(info["model_context_window"])
            if window > 0 { contextWindow = window }
        default:
            return
        }
    }

    // MARK: Helpers

    private static func jsonObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Drops placeholder ids such as Claude Code's `<synthetic>`.
    private static func meaningfulModelID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func int(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: return max(0, number.intValue)
        case let string as String: return max(0, Int(string) ?? 0)
        default: return 0
        }
    }
}
