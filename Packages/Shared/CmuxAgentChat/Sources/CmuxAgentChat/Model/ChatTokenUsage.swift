import Foundation

/// Token counts for one or more agent API responses, normalized across
/// providers.
///
/// The providers disagree about what "input tokens" means, and the
/// disagreement is silent: both write a key called `input_tokens` and the
/// two keys mean different things.
///
/// - Claude Code's `input_tokens` counts *only* tokens that were neither
///   read from nor written to the prompt cache. `cache_read_input_tokens`
///   and `cache_creation_input_tokens` sit beside it and are not included
///   in it.
/// - Codex's `input_tokens` counts the *whole* prompt, with
///   `cached_input_tokens` as a subset of it. Its own `total_tokens` is
///   `input_tokens + output_tokens`, which only adds up because the cached
///   part is already inside `input_tokens`.
///
/// So mapping both providers' `input_tokens` onto one field overstates
/// Codex's uncached input by the entire cached prompt, which for a long
/// session is nearly the whole thing. This type stores the three input
/// kinds separately instead, and each extractor is responsible for
/// converting into them.
public struct ChatTokenUsage: Sendable, Equatable {
    /// Input tokens that were neither served from nor written to the cache.
    public var freshInputTokens: Int

    /// Input tokens served from the prompt cache.
    public var cacheReadTokens: Int

    /// Input tokens written into the prompt cache.
    public var cacheWriteTokens: Int

    /// Tokens the model generated, including any reasoning tokens.
    public var outputTokens: Int

    /// The reasoning share of ``outputTokens``.
    ///
    /// Both providers bill reasoning as output and count it inside their
    /// output total, so this is a breakdown and never an addend. Adding it
    /// to a total double-counts it.
    public var reasoningOutputTokens: Int

    /// Creates a usage value.
    ///
    /// - Parameters:
    ///   - freshInputTokens: Uncached input tokens.
    ///   - cacheReadTokens: Input tokens read from the cache.
    ///   - cacheWriteTokens: Input tokens written to the cache.
    ///   - outputTokens: Generated tokens, reasoning included.
    ///   - reasoningOutputTokens: The reasoning share of the output.
    public init(
        freshInputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0
    ) {
        self.freshInputTokens = freshInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    /// Every input token, cached or not.
    public var inputTokens: Int {
        freshInputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// Every token, input and output.
    ///
    /// Deliberately excludes ``reasoningOutputTokens``, which is already
    /// inside ``outputTokens``.
    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Whether every count is zero.
    public var isEmpty: Bool {
        totalTokens == 0 && reasoningOutputTokens == 0
    }

    /// Adds two usage values field by field.
    ///
    /// - Parameters:
    ///   - lhs: The left value.
    ///   - rhs: The right value.
    /// - Returns: The field-wise sum.
    public static func + (lhs: ChatTokenUsage, rhs: ChatTokenUsage) -> ChatTokenUsage {
        ChatTokenUsage(
            freshInputTokens: lhs.freshInputTokens + rhs.freshInputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens
        )
    }

    /// Adds a usage value into this one.
    ///
    /// - Parameters:
    ///   - lhs: The value to add into.
    ///   - rhs: The value to add.
    public static func += (lhs: inout ChatTokenUsage, rhs: ChatTokenUsage) {
        lhs = lhs + rhs
    }
}

/// How much of a provider's usage allowance a session has consumed.
///
/// Codex writes this into its rollout on every token count. Claude Code
/// does not put limit state in its transcript at all, so this stays `nil`
/// for Claude sessions; the absence is the honest answer rather than a
/// zero.
public struct ChatUsageRateLimit: Sendable, Equatable {
    /// Percentage of the window's allowance used, 0 to 100.
    public var usedPercent: Double

    /// Length of the rolling window in minutes.
    public var windowMinutes: Int?

    /// When the window resets, when the provider says.
    public var resetsAt: Date?

    /// Creates a rate limit reading.
    ///
    /// - Parameters:
    ///   - usedPercent: Percentage of the allowance used.
    ///   - windowMinutes: Window length in minutes.
    ///   - resetsAt: When the window resets.
    public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

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
    /// Keyed by the provider's own model identifier. A session that
    /// switched models mid-run has an entry per model.
    public var usageByModel: [String: ChatTokenUsage]

    /// Distinct API responses counted.
    public var responses: Int

    /// Repeated reports of an already-counted response that were skipped.
    ///
    /// Non-zero is normal, not a warning: both providers repeat usage by
    /// design. A caller that wants to prove deduplication is working can
    /// watch this climb.
    public var duplicateReports: Int

    /// Usage blocks skipped because they carried no response identity.
    ///
    /// These are not counted, so a non-zero value means the total is an
    /// undercount. That is the deliberate direction to be wrong in: without
    /// an identity there is no way to tell a fresh response from the same
    /// one reported again, and counting it risks the large overstatement
    /// deduplication exists to prevent. In practice this stays zero; a
    /// climbing value means a provider changed its format.
    public var unidentifiedReports: Int

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
    ///   - contextTokens: Tokens currently in the context window.
    ///   - contextWindowTokens: The context window size.
    ///   - rateLimit: The provider's allowance state.
    public init(
        usage: ChatTokenUsage = ChatTokenUsage(),
        usageByModel: [String: ChatTokenUsage] = [:],
        responses: Int = 0,
        duplicateReports: Int = 0,
        unidentifiedReports: Int = 0,
        contextTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        rateLimit: ChatUsageRateLimit? = nil
    ) {
        self.usage = usage
        self.usageByModel = usageByModel
        self.responses = responses
        self.duplicateReports = duplicateReports
        self.unidentifiedReports = unidentifiedReports
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
