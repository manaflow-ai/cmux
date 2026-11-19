import Foundation

/// The account's current plan and the billing system that grants it.
///
/// The server's optional `manageUrl` is deliberately not decoded: the App
/// Store build must not show a link to web billing.
public struct BillingCurrentPlan: Sendable, Equatable, Codable {
    /// The granted plan, `free` when there is none.
    public let planID: BillingPlanID
    /// The billing system that grants ``planID``.
    public let source: BillingPlanSource

    /// Creates a current-plan value.
    /// - Parameters:
    ///   - planID: The granted plan.
    ///   - source: The billing system that grants it.
    public init(planID: BillingPlanID, source: BillingPlanSource) {
        self.planID = planID
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case planID = "planId"
        case source
    }
}
