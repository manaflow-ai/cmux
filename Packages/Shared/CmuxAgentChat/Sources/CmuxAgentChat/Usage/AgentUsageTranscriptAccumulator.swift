import Foundation

/// Folds transcript JSONL lines, in order, into running usage totals for one
/// agent session.
///
/// The accumulator is incremental: feed it each complete line exactly once
/// (``ingest(line:)``), then read ``snapshot(catalog:)`` at any point. Lines
/// that carry no usage are rejected by a cheap byte search before any JSON
/// parsing.
///
/// - Claude Code writes one `assistant` line per content block, repeating the
///   same `message.id` and `message.usage` (the final line carries the final
///   output count). Usage is therefore counted once per message id, using the
///   last line seen for it. Context size is the prompt size of the latest
///   main-chain request: `input_tokens + cache_creation_input_tokens +
///   cache_read_input_tokens`. Sidechain (subagent) lines count toward cost
///   but not the main context.
/// - Codex `token_count` events already carry cumulative totals
///   (`info.total_token_usage`), the latest request (`info.last_token_usage`),
///   and the window (`info.model_context_window`); the latest event wins. The
///   model comes from `turn_context`.
public struct AgentUsageTranscriptAccumulator: Sendable {
    /// Which transcript format this accumulator parses.
    public let source: AgentUsageSource

    private var modelID: String?

    // Claude state.
    private var committedMessageIDs: Set<String> = []
    private var committedCostUSD: Double = 0
    private var hasUnpricedUsage = false
    private var pendingMessageID: String?
    private var pendingModelID: String?
    private var pendingUsage: AgentUsageTokenCounts = .zero
    private var claudeContextTokens: Int?

    // Codex state.
    private var codexTotals: AgentUsageTokenCounts?
    private var codexContextTokens: Int?
    private var codexContextWindow: Int?

    private let catalog: AgentModelCatalog

    /// Creates an empty accumulator.
    ///
    /// - Parameters:
    ///   - source: The transcript format.
    ///   - catalog: Model table used to price Claude messages as they are
    ///     committed (a session can switch models mid-way).
    public init(source: AgentUsageSource, catalog: AgentModelCatalog = AgentModelCatalog()) {
        self.source = source
        self.catalog = catalog
    }

    private static let claudeUsageMarker = Data(#""usage""#.utf8)
    private static let codexTokenCountMarker = Data(#""token_count""#.utf8)
    private static let codexTurnContextMarker = Data(#""turn_context""#.utf8)

    /// Folds one complete JSONL line (without its trailing newline).
    ///
    /// - Parameter line: The raw line bytes. Malformed or irrelevant lines
    ///   are ignored.
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

    /// The usage summary so far, or `nil` before any model or usage is known.
    ///
    /// - Returns: A snapshot combining model, context, and estimated cost.
    public func snapshot() -> AgentUsageSnapshot? {
        switch source {
        case .claude: return claudeSnapshot()
        case .codex: return codexSnapshot()
        }
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
        let messageID = message["id"] as? String

        if let messageID, committedMessageIDs.contains(messageID) { return }
        if messageID == nil || messageID != pendingMessageID {
            commitPendingClaudeMessage()
            pendingMessageID = messageID
        }
        pendingUsage = counts
        pendingModelID = model ?? pendingModelID
        if messageID == nil {
            // No id to de-duplicate on: count this line on its own.
            commitPendingClaudeMessage()
        }
        guard !isSidechain else { return }
        if let model { modelID = model }
        if counts.totalInput > 0 { claudeContextTokens = counts.totalInput }
    }

    private mutating func commitPendingClaudeMessage() {
        defer {
            pendingMessageID = nil
            pendingModelID = nil
            pendingUsage = .zero
        }
        guard pendingUsage != .zero else { return }
        if let pendingMessageID { committedMessageIDs.insert(pendingMessageID) }
        if let messageCost = cost(of: pendingUsage, modelID: pendingModelID ?? modelID) {
            committedCostUSD += messageCost
        } else {
            hasUnpricedUsage = true
        }
    }

    private func cost(of counts: AgentUsageTokenCounts, modelID: String?) -> Double? {
        guard let modelID, let pricing = catalog.info(forModelID: modelID)?.pricing else { return nil }
        return pricing.estimatedCostUSD(for: counts)
    }

    private func claudeSnapshot() -> AgentUsageSnapshot? {
        guard let modelID, let info = catalog.info(forModelID: modelID) else { return nil }
        let contextTokens = claudeContextTokens ?? 0
        var window = info.contextWindow
        // A request larger than the table's window proves a 1M window
        // (for example a `[1m]` model whose id carries no suffix).
        if let current = window, contextTokens > current {
            window = AgentModelCatalog.oneMillionContextWindow
        }
        var cost: Double? = committedCostUSD
        var unpriced = hasUnpricedUsage
        if pendingUsage != .zero {
            if let pendingCost = self.cost(of: pendingUsage, modelID: pendingModelID ?? modelID) {
                cost = committedCostUSD + pendingCost
            } else {
                unpriced = true
            }
        }
        if unpriced { cost = nil }
        return AgentUsageSnapshot(
            modelID: modelID,
            modelDisplayName: info.displayName,
            contextTokens: contextTokens,
            contextWindow: window,
            estimatedCostUSD: cost
        )
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
            if let total = info["total_token_usage"] as? [String: Any] {
                codexTotals = Self.codexCounts(total)
            }
            if let last = info["last_token_usage"] as? [String: Any] {
                let total = Self.int(last["total_tokens"])
                codexContextTokens = total > 0
                    ? total
                    : Self.int(last["input_tokens"]) + Self.int(last["output_tokens"])
            }
            let window = Self.int(info["model_context_window"])
            if window > 0 { codexContextWindow = window }
        default:
            return
        }
    }

    private func codexSnapshot() -> AgentUsageSnapshot? {
        guard let modelID,
              let info = catalog.info(forModelID: modelID, reportedContextWindow: codexContextWindow) else {
            return nil
        }
        return AgentUsageSnapshot(
            modelID: modelID,
            modelDisplayName: info.displayName,
            contextTokens: codexContextTokens ?? 0,
            contextWindow: info.contextWindow,
            estimatedCostUSD: codexTotals.flatMap { totals in
                info.pricing.map { $0.estimatedCostUSD(for: totals) }
            }
        )
    }

    /// Codex/OpenAI `input_tokens` includes cached input; split it so cached
    /// tokens are priced at the cached rate only once.
    private static func codexCounts(_ usage: [String: Any]) -> AgentUsageTokenCounts {
        let input = int(usage["input_tokens"])
        let cached = int(usage["cached_input_tokens"])
        let cacheWrite = int(usage["cache_write_input_tokens"])
        return AgentUsageTokenCounts(
            uncachedInput: max(0, input - cached - cacheWrite),
            cacheWrite5m: cacheWrite,
            cacheRead: cached,
            output: int(usage["output_tokens"])
        )
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
