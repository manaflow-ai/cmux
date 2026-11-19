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
