import Foundation

/// An estimated API cost and whether it is complete.
public struct AgentUsageCost: Sendable, Equatable {
    /// Estimated cost in US dollars at published list prices.
    public let usd: Double
    /// `true` when some usage could not be priced (unknown model, or a
    /// transcript line too large to read), so the real figure is higher.
    public let isLowerBound: Bool
    /// Whether any usage was actually priced. A cost built only from
    /// unknown models carries no information and is not displayed.
    public let hasPricedUsage: Bool

    /// Creates a cost.
    public init(usd: Double, isLowerBound: Bool, hasPricedUsage: Bool = true) {
        self.usd = usd
        self.isLowerBound = isLowerBound
        self.hasPricedUsage = hasPricedUsage
    }

    /// This cost when it is worth showing, or `nil` when nothing was priced.
    public var displayable: Self? {
        hasPricedUsage ? self : nil
    }

    /// Adds two estimates; the sum is a lower bound if either part is.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            usd: lhs.usd + rhs.usd,
            isLowerBound: lhs.isLowerBound || rhs.isLowerBound,
            hasPricedUsage: lhs.hasPricedUsage || rhs.hasPricedUsage
        )
    }

    /// Adds two optional estimates; `nil` (unknown) is contagious.
    static func combine(_ lhs: Self?, _ rhs: Self?) -> Self? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
}
