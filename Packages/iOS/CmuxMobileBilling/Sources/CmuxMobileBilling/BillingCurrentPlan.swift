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
    /// The free trial the account is in now; nil when it is in none.
    public let trial: BillingActiveTrial?

    /// Creates a current-plan value.
    /// - Parameters:
    ///   - planID: The granted plan.
    ///   - source: The billing system that grants it.
    public init(planID: BillingPlanID, source: BillingPlanSource, trial: BillingActiveTrial? = nil) {
        self.planID = planID
        self.source = source
        self.trial = trial
    }

    enum CodingKeys: String, CodingKey {
        case planID = "planId"
        case source
        case trial
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planID = try container.decode(BillingPlanID.self, forKey: .planID)
        source = try container.decode(BillingPlanSource.self, forKey: .source)
        trial = try? container.decodeIfPresent(BillingActiveTrial.self, forKey: .trial)
    }
}
