public import Foundation

/// Coding-agent usage shown next to an agent's sidebar status entry: the
/// model, how full its context window is, and an estimated API cost.
///
/// The app target samples this from the agent transcript off the main actor
/// and stores it per status key in ``WorkspaceSidebarMetadataModel``; the
/// row renders it only when `sidebar.showAgentUsage` is on.
public struct SidebarAgentUsage: Equatable, Sendable {
    /// Short model name (`Opus 4.8`, `gpt-5-codex`).
    public let modelName: String
    /// Fraction of the context window in use (`0...1`), or `nil` when the
    /// window is unknown.
    public let contextFraction: Double?
    /// Estimated pay-as-you-go cost in US dollars, or `nil` when the model
    /// has no known list price.
    public let estimatedCostUSD: Double?
    /// `true` when part of the usage could not be priced, so the real cost
    /// is higher than ``estimatedCostUSD``.
    public let costIsLowerBound: Bool

    /// Creates a usage value.
    public init(
        modelName: String,
        contextFraction: Double?,
        estimatedCostUSD: Double?,
        costIsLowerBound: Bool = false
    ) {
        self.modelName = modelName
        self.contextFraction = contextFraction
        self.estimatedCostUSD = estimatedCostUSD
        self.costIsLowerBound = costIsLowerBound
    }
}
