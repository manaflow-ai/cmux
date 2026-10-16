import Foundation

/// Token counts split by billing class, used for cost estimation.
///
/// `uncachedInput` excludes cache reads and cache writes, matching the
/// Anthropic `usage.input_tokens` convention. Codex totals (where
/// `input_tokens` includes cached input) are normalized to this shape by the
/// parser.
public struct AgentUsageTokenCounts: Sendable, Equatable {
    /// Input tokens billed at the base input price.
    public var uncachedInput: Int
    /// Input tokens written to a 5-minute prompt cache.
    public var cacheWrite5m: Int
    /// Input tokens written to a 1-hour prompt cache.
    public var cacheWrite1h: Int
    /// Input tokens served from the prompt cache.
    public var cacheRead: Int
    /// Output tokens (including any reasoning/thinking tokens).
    public var output: Int

    /// Creates a count; every class defaults to zero.
    public init(
        uncachedInput: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0
    ) {
        self.uncachedInput = uncachedInput
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    /// All zeros.
    public static let zero = Self()

    /// Every input class summed: the prompt size of one request.
    public var totalInput: Int {
        uncachedInput + cacheWrite5m + cacheWrite1h + cacheRead
    }

    /// Adds two counts class by class.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output
        )
    }
}
