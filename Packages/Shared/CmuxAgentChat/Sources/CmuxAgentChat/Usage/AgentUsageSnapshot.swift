import Foundation

/// A point-in-time summary of one agent session's usage, sampled from its
/// transcript: which model it runs, how full the context window is, and an
/// estimated pay-as-you-go API cost.
public struct AgentUsageSnapshot: Sendable, Equatable {
    /// The raw model id from the transcript.
    public let modelID: String
    /// Short model name for display (`Opus 4.8`, `gpt-5-codex`).
    public let modelDisplayName: String
    /// Tokens occupying the context window as of the latest main-thread
    /// request.
    public let contextTokens: Int
    /// The context window size, or `nil` when unknown.
    public let contextWindow: Int?
    /// Estimated cost of the whole session (main thread plus subagents), or
    /// `nil` when it cannot be estimated: the model has no price row, or the
    /// transcript was too large to read from the start.
    public let estimatedCost: AgentUsageCost?

    /// Creates a snapshot.
    public init(
        modelID: String,
        modelDisplayName: String,
        contextTokens: Int,
        contextWindow: Int?,
        estimatedCost: AgentUsageCost?
    ) {
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.estimatedCost = estimatedCost
    }

    /// Fraction of the context window in use, clamped to `0...1`, or `nil`
    /// when the window is unknown.
    public var contextFraction: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return min(max(Double(contextTokens) / Double(contextWindow), 0), 1)
    }

    /// A copy with a different cost (used to fold in subagent transcripts).
    public func withEstimatedCost(_ cost: AgentUsageCost?) -> Self {
        Self(
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            estimatedCost: cost
        )
    }
}
