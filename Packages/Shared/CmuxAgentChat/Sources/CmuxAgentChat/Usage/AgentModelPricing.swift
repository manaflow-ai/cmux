import Foundation

/// Published per-million-token list prices for one model, in US dollars.
///
/// These are public API list prices used only to *estimate* what a session
/// would cost at pay-as-you-go rates. Not modelled: subscriptions (a Claude
/// plan is not billed per token), batch and priority tiers, regional and
/// partner (Bedrock/Vertex/Foundry) pricing, data-residency multipliers,
/// long-context premiums of older 1M betas, fast mode, and server-tool fees
/// such as web search. The result is labelled as an estimate wherever shown.
public struct AgentModelPricing: Sendable, Equatable {
    /// Base input price per million tokens.
    public let inputPerMTok: Double
    /// Output price per million tokens.
    public let outputPerMTok: Double
    /// 5-minute cache-write price per million tokens.
    public let cacheWrite5mPerMTok: Double
    /// 1-hour cache-write price per million tokens.
    public let cacheWrite1hPerMTok: Double
    /// Cache-read price per million tokens.
    public let cacheReadPerMTok: Double

    /// Creates a price row.
    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double,
        cacheReadPerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
    }

    /// Anthropic pricing shape: cache writes cost 1.25x (5m) and 2x (1h)
    /// the input price; the cache-read price is model specific.
    static func anthropic(input: Double, output: Double, cacheRead: Double) -> Self {
        Self(
            inputPerMTok: input,
            outputPerMTok: output,
            cacheWrite5mPerMTok: input * 1.25,
            cacheWrite1hPerMTok: input * 2,
            cacheReadPerMTok: cacheRead
        )
    }

    /// Estimated cost of `tokens` at these prices, in US dollars.
    ///
    /// - Parameter tokens: Token counts split by billing class.
    /// - Returns: The dollar estimate.
    public func estimatedCostUSD(for tokens: AgentUsageTokenCounts) -> Double {
        let dollars = Double(tokens.uncachedInput) * inputPerMTok
            + Double(tokens.cacheWrite5m) * cacheWrite5mPerMTok
            + Double(tokens.cacheWrite1h) * cacheWrite1hPerMTok
            + Double(tokens.cacheRead) * cacheReadPerMTok
            + Double(tokens.output) * outputPerMTok
        return dollars / 1_000_000
    }
}
