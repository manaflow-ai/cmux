import Foundation

/// Token and spend totals for one machine over the usage window, as
/// `GET /api/coderouter/vm-usage/team` reports them.
struct MachineUsageTotals: Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    /// What the same traffic would have cost at list API prices.
    let apiEquivalentUsd: Double

    /// Nothing to show for a machine that has not routed a single token.
    var isEmpty: Bool { totalTokens <= 0 && apiEquivalentUsd <= 0 }
}

