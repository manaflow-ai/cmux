import Foundation

/// Token and spend totals for one machine over the usage window, as
/// `GET /api/coderouter/vm-usage/team` reports them.
public struct MachineUsageTotals: Equatable, Sendable {
    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        apiEquivalentUsd: Double
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.apiEquivalentUsd = apiEquivalentUsd
    }

    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    /// What the same traffic would have cost at list API prices.
    public let apiEquivalentUsd: Double

    /// Nothing to show for a machine that has not routed a single token.
    public var isEmpty: Bool { totalTokens <= 0 && apiEquivalentUsd <= 0 }
}
