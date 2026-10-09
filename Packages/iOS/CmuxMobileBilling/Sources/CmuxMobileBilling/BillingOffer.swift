import Foundation

/// A plan on sale: the server's product reference joined with StoreKit's
/// product for its localized price.
public struct BillingOffer: Sendable, Equatable, Hashable, Identifiable {
    /// The cmux plan the offer grants.
    public let planID: BillingPlanID
    /// The StoreKit product.
    public let product: StoreProduct

    /// The App Store product id.
    public var id: String { product.id }

    /// Creates an offer.
    /// - Parameters:
    ///   - planID: The plan the product grants.
    ///   - product: The StoreKit product.
    public init(planID: BillingPlanID, product: StoreProduct) {
        self.planID = planID
        self.product = product
    }
}
