import Foundation

/// How often a subscription renews. The server sells each plan monthly and,
/// for some plans, yearly (`docs/billing/ios-in-app-purchases.md`).
public enum BillingPeriod: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    case monthly
    case yearly

    /// The period of a `<bundleId>.<plan>.<period>` product id, or nil when the
    /// suffix names neither period.
    /// - Parameter productID: An App Store product id.
    public init?(productID: String) {
        if productID.hasSuffix(".yearly") {
            self = .yearly
        } else if productID.hasSuffix(".monthly") {
            self = .monthly
        } else {
            return nil
        }
    }

    public static func < (lhs: BillingPeriod, rhs: BillingPeriod) -> Bool {
        lhs == .monthly && rhs == .yearly
    }
}
