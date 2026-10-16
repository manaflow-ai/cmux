import Foundation

/// One App Store product the server currently sells to this bundle.
public struct BillingProductReference: Sendable, Equatable, Hashable, Codable {
    /// The App Store product id, `<bundleId>.<plan>.monthly`.
    public let productID: String
    /// The cmux plan the product grants.
    public let planID: BillingPlanID
    /// How often the product renews.
    public let billingPeriod: BillingPeriod

    /// Creates a product reference.
    /// - Parameters:
    ///   - productID: The App Store product id.
    ///   - planID: The cmux plan it grants.
    ///   - billingPeriod: How often it renews; nil reads it from the
    ///     product id suffix, and monthly when the suffix names no period.
    public init(productID: String, planID: BillingPlanID, billingPeriod: BillingPeriod? = nil) {
        self.productID = productID
        self.planID = planID
        self.billingPeriod = billingPeriod ?? BillingPeriod(productID: productID) ?? .monthly
    }

    enum CodingKeys: String, CodingKey {
        case productID = "productId"
        case planID = "planId"
        case billingPeriod
    }

    /// Decodes a product; a missing or unknown `billingPeriod` (a server that
    /// predates yearly plans) falls back to the product id suffix.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let productID = try container.decode(String.self, forKey: .productID)
        let planID = try container.decode(BillingPlanID.self, forKey: .planID)
        let raw = try container.decodeIfPresent(String.self, forKey: .billingPeriod)
        self.init(productID: productID, planID: planID, billingPeriod: raw.flatMap(BillingPeriod.init(rawValue:)))
    }
}
