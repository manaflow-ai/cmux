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
    /// The classic Go plan.
    public static let go = BillingPlanID(rawValue: "go")
    /// The classic Pro plan.
    public static let pro = BillingPlanID(rawValue: "pro")
    /// The classic Max plan.
    public static let max = BillingPlanID(rawValue: "max")
    /// The cmux NEXT Plus plan, sold in the cmux-next apps.
    public static let nextPlus = BillingPlanID(rawValue: "next_plus")
    /// The cmux NEXT Pro plan, sold in the cmux-next apps.
    public static let nextPro = BillingPlanID(rawValue: "next_pro")
    /// The cmux NEXT Max plan, sold in the cmux-next apps.
    public static let nextMax = BillingPlanID(rawValue: "next_max")

    /// Whether this is a cmux NEXT plan rather than a classic one.
    public var isNext: Bool {
        rawValue.hasPrefix("next_")
    }

    /// Ordering rank within a plan family: Go < Pro < Max and
    /// Plus < Pro < Max. An app sells one family, so ranks never need to
    /// order a classic plan against a NEXT one. Unknown plans sort first.
    public var rank: Int {
        switch rawValue {
        case Self.go.rawValue, Self.nextPlus.rawValue: 1
        case Self.pro.rawValue, Self.nextPro.rawValue: 2
        case Self.max.rawValue, Self.nextMax.rawValue: 3
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
