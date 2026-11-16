import Foundation

/// The response of `POST /api/billing/apple/transactions` after the server
/// verified a transaction and applied its entitlement.
public struct BillingTransactionReceipt: Sendable, Equatable, Codable {
    /// The plan the server now grants from this subscription.
    public let planID: BillingPlanID
    /// The subscription status, such as `active` or `expired`.
    public let status: String
    /// The expiry as the server's ISO 8601 string, when known.
    public let expiresAt: String?

    /// Creates a receipt.
    /// - Parameters:
    ///   - planID: The plan granted.
    ///   - status: The subscription status.
    ///   - expiresAt: The expiry string, when known.
    public init(planID: BillingPlanID, status: String, expiresAt: String?) {
        self.planID = planID
        self.status = status
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case planID = "planId"
        case status
        case expiresAt
    }
}
