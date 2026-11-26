import Foundation

/// Everything one transcript says about what it spent.
///
/// Carries no prices. Converting tokens to money needs a per-model price
/// table, an answer for subscription plans where per-token prices do not
/// apply, and a decision about how stale a bundled table may get. Those
/// are product decisions, so this type stops at counts and leaves them to
/// the caller.
public struct ChatUsageTotals: Sendable, Equatable {
    /// Usage summed over every distinct API response in the transcript.
    public var usage: ChatTokenUsage

    /// Usage split by the model that produced it.
    ///
    /// Keyed by the provider's own model identifier. A session that switched
    /// models mid-run has an entry per model. A cumulative Codex fallback has
    /// no response-level model identity, so the split can sum to less than
    /// ``usage``.
    public var usageByModel: [String: ChatTokenUsage]

    /// Distinct API responses counted.
    public var responses: Int

    /// Repeated reports of a response that was already counted.
    ///
    /// Non-zero is normal, not a warning: both providers repeat usage by
    /// design. A caller that wants to prove deduplication is working can
    /// watch this climb, within one limit: identities are remembered in a
    /// bounded recent window, so a transcript with more distinct responses
    /// than the window holds can count a very old identity a second time
    /// without recording it here. The window is far larger than the widest
    /// repeat distance either provider produces. A repeat is usually dropped, but a Claude repeat
    /// carrying larger counts than the copy already counted replaces it,
    /// because a streaming response's early lines carry placeholder
    /// output counts. Either way it counts here.
    public var duplicateReports: Int

    /// Usage blocks skipped because they carried no response identity.
    ///
    /// These are not counted, so a non-zero value means the total is an
    /// undercount. That is the deliberate direction to be wrong in: without
    /// an identity there is no way to tell a fresh response from the same
    /// one reported again, and counting it risks the large overstatement
    /// deduplication exists to prevent.
    ///
    /// Also counts a usage block that carries no count field this parser
    /// recognizes, which is the one format change it can notice. In
    /// practice both stay zero. It is not a general format alarm: a
    /// provider that renames only *some* count keys, or adds a new kind of
    /// token, leaves this at zero and quietly undercounts.
    public var unidentifiedReports: Int

    /// Whether cumulative-only Codex usage crossed an unmarked decrease.
    ///
    /// Without a structured thread/reset event, the accumulator cannot know
    /// whether the smaller value corrected one run or began another. The
    /// reported cumulative usage is then the latest known snapshot rather
    /// than a guessed sum of runs.
    public var cumulativeUsageIsAmbiguous: Bool

    /// Tokens currently occupying the context window, when the provider
    /// reports it.
    public var contextTokens: Int?

    /// The model's context window size, when the provider reports it.
    public var contextWindowTokens: Int?

    /// The provider's usage allowance state, when it reports it.
    public var rateLimit: ChatUsageRateLimit?

    /// Creates a usage summary.
    ///
    /// - Parameters:
    ///   - usage: Usage over every distinct response.
    ///   - usageByModel: Usage split by model identifier.
    ///   - responses: Distinct responses counted.
    ///   - duplicateReports: Repeated reports skipped.
    ///   - unidentifiedReports: Usage blocks skipped for lack of an identity.
    ///   - cumulativeUsageIsAmbiguous: Whether a cumulative-only transition
    ///     lacked a structured run boundary.
    ///   - contextTokens: Tokens currently in the context window.
    ///   - contextWindowTokens: The context window size.
    ///   - rateLimit: The provider's allowance state.
    public init(
        usage: ChatTokenUsage = ChatTokenUsage(),
        usageByModel: [String: ChatTokenUsage] = [:],
        responses: Int = 0,
        duplicateReports: Int = 0,
        unidentifiedReports: Int = 0,
        cumulativeUsageIsAmbiguous: Bool = false,
        contextTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        rateLimit: ChatUsageRateLimit? = nil
    ) {
        self.usage = usage
        self.usageByModel = usageByModel
        self.responses = responses
        self.duplicateReports = duplicateReports
        self.unidentifiedReports = unidentifiedReports
        self.cumulativeUsageIsAmbiguous = cumulativeUsageIsAmbiguous
        self.contextTokens = contextTokens
        self.contextWindowTokens = contextWindowTokens
        self.rateLimit = rateLimit
    }

    /// The share of the context window in use, 0 to 1, when both the
    /// occupancy and the window size are known.
    public var contextUsedFraction: Double? {
        guard let contextTokens, let contextWindowTokens, contextWindowTokens > 0 else {
            return nil
        }
        return Double(contextTokens) / Double(contextWindowTokens)
    }
}
