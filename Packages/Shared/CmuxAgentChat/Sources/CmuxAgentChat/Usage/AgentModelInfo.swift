import Foundation

/// What cmux knows about one model id: a short display name, its context
/// window, and (when listed) its published prices.
public struct AgentModelInfo: Sendable, Equatable {
    /// Short display name, e.g. `Opus 4.8` or `gpt-5-codex`.
    public let displayName: String
    /// Context window in tokens, or `nil` when neither the transcript nor
    /// the built-in table knows it (the context percentage is then omitted).
    public let contextWindow: Int?
    /// Published list prices, or `nil` when the model is not in the price
    /// table (cost is then omitted rather than guessed).
    public let pricing: AgentModelPricing?

    /// Creates a model description.
    public init(displayName: String, contextWindow: Int?, pricing: AgentModelPricing?) {
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.pricing = pricing
    }
}
