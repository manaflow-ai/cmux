public import Foundation

/// The engine a turn runs on, as the app chose it (``ChiefTurnContext/engine``).
public struct ChiefTurnEngine: Sendable, Equatable, Codable {
    /// The harness (`claude`, `codex`).
    public var harness: String
    /// The model id the harness runs.
    public var model: String
    /// The effort level; nil for the model's default.
    public var effort: String?

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - harness: The harness name.
    ///   - model: The model id.
    ///   - effort: The effort level, nil for the default.
    public init(harness: String, model: String, effort: String? = nil) {
        self.harness = harness
        self.model = model
        self.effort = effort
    }
}

/// Token counts a brain reports for a turn (``ChiefTurnEvent/usage(_:)``).
public struct ChiefTurnUsage: Sendable, Equatable {
    /// Input tokens sent without the prompt cache.
    public var inputTokens: Int
    /// Input tokens read from the prompt cache.
    public var cacheReadTokens: Int
    /// Input tokens written to the prompt cache.
    public var cacheWriteTokens: Int

    /// Creates usage counts.
    public init(inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    /// The share of input read from the cache (0...1); nil without input.
    public var cacheHitRate: Double? {
        let total = inputTokens + cacheReadTokens + cacheWriteTokens
        return total > 0 ? Double(cacheReadTokens) / Double(total) : nil
    }
}

/// What one finished turn took: the Chief settings panel's "Last turn" line
/// (cmux-next `HomeEngineTurn`).
///
/// ```swift
/// if let stats = await owner.lastTurnStats(in: conversation) {
///     print(stats.engine?.model ?? "-", stats.duration, stats.toolCalls)
/// }
/// ```
public struct ChiefTurnStats: Sendable, Equatable {
    /// The engine the turn ran on; nil when the app's context named none.
    public var engine: ChiefTurnEngine?
    /// Wall time from the turn's start to its end.
    public var duration: TimeInterval
    /// Tool calls the turn started.
    public var toolCalls: Int
    /// Tool calls that finished failed.
    public var failedToolCalls: Int
    /// The share of input read from the prompt cache; nil when the brain did not report usage.
    public var cacheHitRate: Double?
    /// Whether the turn failed.
    public var failed: Bool
    /// Whether the user stopped the turn.
    public var stopped: Bool
    /// When the turn ended.
    public var endedAt: Date

    /// Creates stats.
    public init(engine: ChiefTurnEngine?, duration: TimeInterval, toolCalls: Int, failedToolCalls: Int,
                cacheHitRate: Double?, failed: Bool, stopped: Bool, endedAt: Date) {
        self.engine = engine
        self.duration = duration
        self.toolCalls = toolCalls
        self.failedToolCalls = failedToolCalls
        self.cacheHitRate = cacheHitRate
        self.failed = failed
        self.stopped = stopped
        self.endedAt = endedAt
    }
}
