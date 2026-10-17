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
        Self.saturatedSum(
            Self.saturatedSum(freshInputTokens, cacheReadTokens),
            cacheWriteTokens
        )
    }

    /// Every token, input and output.
    ///
    /// Deliberately excludes ``reasoningOutputTokens``, which is already
    /// inside ``outputTokens``.
    public var totalTokens: Int {
        Self.saturatedSum(inputTokens, outputTokens)
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
            freshInputTokens: Self.saturatedSum(lhs.freshInputTokens, rhs.freshInputTokens),
            cacheReadTokens: Self.saturatedSum(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: Self.saturatedSum(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            outputTokens: Self.saturatedSum(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: Self.saturatedSum(
                lhs.reasoningOutputTokens,
                rhs.reasoningOutputTokens
            )
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

    /// Adds two integer counts without allowing extreme input to trap.
    ///
    /// A transcript's counts come from a provider, so a corrupt or hostile line
    /// can carry a value near `Int.max`. Saturating keeps one bad line from
    /// taking down the accumulation of every good one.
    static func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return lhs >= 0 ? Int.max : Int.min
    }
}
