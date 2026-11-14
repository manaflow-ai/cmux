import Foundation

/// A plan on sale: the server's product reference joined with StoreKit's
/// product for its localized price.
public struct BillingOffer: Sendable, Equatable, Hashable, Identifiable {
    /// The cmux plan the offer grants.
    public let planID: BillingPlanID
    /// The StoreKit product.
    public let product: StoreProduct
    /// How often the product renews.
    public let billingPeriod: BillingPeriod

    /// The App Store product id.
    public var id: String { product.id }

    /// Creates an offer.
    /// - Parameters:
    ///   - planID: The plan the product grants.
    ///   - product: The StoreKit product.
    ///   - billingPeriod: How often it renews.
    public init(planID: BillingPlanID, product: StoreProduct, billingPeriod: BillingPeriod = .monthly) {
        self.planID = planID
        self.product = product
        self.billingPeriod = billingPeriod
    }
}

extension Array where Element == BillingOffer {
    /// The yearly saving of `plan` against twelve monthly payments, from the
    /// StoreKit prices, rounded down to a whole percent so the app never
    /// overstates it. Nil when the plan is not sold in both periods in one
    /// currency, or the saving is under 1%.
    /// - Parameter plan: The plan to compare.
    /// - Returns: The saving in percent, such as 22.
    public func yearlySavingsPercent(for plan: BillingPlanID) -> Int? {
        guard let monthly = first(where: { $0.planID == plan && $0.billingPeriod == .monthly })?.product,
              let yearly = first(where: { $0.planID == plan && $0.billingPeriod == .yearly })?.product,
              let monthlyPrice = monthly.price, let yearlyPrice = yearly.price,
              monthly.currencyCode == yearly.currencyCode,
              monthlyPrice > 0
        else { return nil }
        let fullYear = NSDecimalNumber(decimal: monthlyPrice * 12).doubleValue
        let saving = (1 - NSDecimalNumber(decimal: yearlyPrice).doubleValue / fullYear) * 100
        let percent = Int(saving.rounded(.down))
        return percent >= 1 ? percent : nil
    }

    /// The largest ``yearlySavingsPercent(for:)`` across the plans on sale.
    public var bestYearlySavingsPercent: Int? {
        Set(map(\.planID)).compactMap { yearlySavingsPercent(for: $0) }.max()
    }
}
