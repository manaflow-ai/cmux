import Foundation

/// Published per-MTok prices for the models most commonly seen in local
/// Claude Code / Codex transcripts. Matching is by substring so dated model
/// IDs (e.g. `claude-sonnet-4-20250514`) resolve without an exact table hit.
/// Unknown models yield no estimate rather than a wrong one.
struct AgentUsagePricing: Equatable, Sendable {
    /// USD per million non-cached input tokens.
    var inputPerMTok: Double
    /// USD per million output tokens.
    var outputPerMTok: Double
    /// USD per million cache-read tokens.
    var cacheReadPerMTok: Double
    /// USD per million cache-write tokens.
    var cacheWritePerMTok: Double

    /// Computes the USD cost of a token breakdown at this price point.
    func cost(for tokens: AgentUsageTokens) -> Double {
        let mTok = 1_000_000.0
        return (Double(tokens.input) * inputPerMTok
            + Double(tokens.output) * outputPerMTok
            + Double(tokens.cacheRead) * cacheReadPerMTok
            + Double(tokens.cacheWrite) * cacheWritePerMTok) / mTok
    }

    /// Returns the price table entry whose model family matches `model`,
    /// or nil for unknown models (no estimate is better than a wrong one).
    static func pricing(forModel model: String) -> AgentUsagePricing? {
        let normalized = model.lowercased()
        if normalized.contains("opus") {
            return AgentUsagePricing(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.5, cacheWritePerMTok: 18.75)
        }
        if normalized.contains("sonnet") {
            return AgentUsagePricing(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
        }
        if normalized.contains("haiku") {
            return AgentUsagePricing(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.1, cacheWritePerMTok: 1.25)
        }
        if normalized.contains("gpt-5") || normalized.contains("codex") {
            return AgentUsagePricing(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125, cacheWritePerMTok: 0)
        }
        return nil
    }

    /// Best-available USD cost for an event: the cost recorded in the
    /// transcript when present, otherwise an estimate from the price table,
    /// otherwise nil.
    static func estimatedCost(for event: AgentUsageEvent) -> Double? {
        if let recorded = event.recordedCostUSD {
            return recorded
        }
        return pricing(forModel: event.model)?.cost(for: event.tokens)
    }
}
