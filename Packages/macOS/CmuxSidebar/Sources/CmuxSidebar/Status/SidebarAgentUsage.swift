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

    /// Which usage components a row shows (`sidebar.showAgentModel`,
    /// `sidebar.showAgentContext`, `sidebar.showAgentCost`).
    public struct Parts: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The short model name.
        public static let model = Parts(rawValue: 1 << 0)
        /// The context-window percentage.
        public static let context = Parts(rawValue: 1 << 1)
        /// The estimated API cost.
        public static let cost = Parts(rawValue: 1 << 2)
        /// Every component.
        public static let all: Parts = [.model, .context, .cost]

        /// The components whose flag is on.
        public init(model: Bool, context: Bool, cost: Bool) {
            self = []
            if model { insert(.model) }
            if context { insert(.context) }
            if cost { insert(.cost) }
        }
    }
}
