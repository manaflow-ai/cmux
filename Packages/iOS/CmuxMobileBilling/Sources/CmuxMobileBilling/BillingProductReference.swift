import Foundation

/// One App Store product the server currently sells to this bundle.
public struct BillingProductReference: Sendable, Equatable, Hashable, Codable {
    /// The App Store product id, `<bundleId>.<plan>.monthly`.
    public let productID: String
    /// The cmux plan the product grants.
    public let planID: BillingPlanID

    /// Creates a product reference.
    /// - Parameters:
    ///   - productID: The App Store product id.
    ///   - planID: The cmux plan it grants.
    public init(productID: String, planID: BillingPlanID) {
        self.productID = productID
        self.planID = planID
    }

    enum CodingKeys: String, CodingKey {
        case productID = "productId"
        case planID = "planId"
    }
}
