import Foundation

/// A cmux plan identifier as the server reports it (`planId`).
///
/// A struct over the raw string, not a closed enum, so a plan the server adds
/// later decodes and renders by name instead of failing the whole response.
public struct BillingPlanID: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    /// The server's lowercase plan id, such as `pro`.
    public let rawValue: String

    /// Creates a plan id, normalizing case and surrounding whitespace.
    /// - Parameter rawValue: The server's plan id.
    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// No paid plan.
    public static let free = BillingPlanID(rawValue: "free")
    /// The Go plan.
    public static let go = BillingPlanID(rawValue: "go")
    /// The Pro plan.
    public static let pro = BillingPlanID(rawValue: "pro")
    /// The Max plan.
    public static let max = BillingPlanID(rawValue: "max")

    /// Ordering rank: Go < Pro < Max, unknown plans sort before Go.
    public var rank: Int {
        switch rawValue {
        case Self.go.rawValue: 1
        case Self.pro.rawValue: 2
        case Self.max.rawValue: 3
        default: 0
        }
    }

    /// Orders plans from the smallest to the largest.
    public static func < (lhs: BillingPlanID, rhs: BillingPlanID) -> Bool {
        lhs.rank == rhs.rank ? lhs.rawValue < rhs.rawValue : lhs.rank < rhs.rank
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
