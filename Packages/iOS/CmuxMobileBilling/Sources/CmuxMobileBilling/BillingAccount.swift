import Foundation

/// The response of `POST /api/billing/apple/account-token`.
///
/// Carries the per-user `appAccountToken` every purchase must include, whether
/// the account may buy in the App Store, its current plan, and the products
/// the server sells to this bundle (Go is absent when its flag is off).
public struct BillingAccount: Sendable, Equatable, Codable {
    /// The UUID the server minted for this cmux user; passed to StoreKit as
    /// `.appAccountToken` so the server can link the purchase to the user.
    public let appAccountToken: UUID
    /// False when the account pays on the web or through a team.
    public let eligible: Bool
    /// Why ``eligible`` is false; nil when eligible.
    public let reason: BillingIneligibilityReason?
    /// The account's current plan.
    public let currentPlan: BillingCurrentPlan
    /// The products on sale for this bundle.
    public let products: [BillingProductReference]

    /// Creates an account value.
    /// - Parameters:
    ///   - appAccountToken: The server-minted purchase token.
    ///   - eligible: Whether App Store purchases are allowed.
    ///   - reason: Why purchases are not allowed, when they are not.
    ///   - currentPlan: The current plan.
    ///   - products: The products on sale.
    public init(
        appAccountToken: UUID,
        eligible: Bool,
        reason: BillingIneligibilityReason?,
        currentPlan: BillingCurrentPlan,
        products: [BillingProductReference]
    ) {
        self.appAccountToken = appAccountToken
        self.eligible = eligible
        self.reason = reason
        self.currentPlan = currentPlan
        self.products = products
    }

    /// The paid plans the plans screen describes when this build sells none
    /// (an ineligible account gets no products): the NEXT plans this package's
    /// app sells (Plus, Pro, Max), plus any other plan, such as classic Go,
    /// only when the account is on it or it is on sale. Such a plan comes
    /// first, apart from the NEXT plans, so a classic Pro or Max never sits
    /// between NEXT Pro and Max under the same name; each family is smallest
    /// first.
    /// Without these an ineligible account, such as every TestFlight and dev
    /// build in production, saw a plans screen with no plans on it.
    public var catalogPlanIDs: [BillingPlanID] {
        var plans: Set<BillingPlanID> = [.nextPlus, .nextPro, .nextMax]
        plans.formUnion(products.map(\.planID).filter { $0.rank > 0 })
        if currentPlan.planID.rank > 0 { plans.insert(currentPlan.planID) }
        return plans.sorted { ($0.isNext ? 1 : 0, $0) < ($1.isNext ? 1 : 0, $1) }
    }

    enum CodingKeys: String, CodingKey {
        case appAccountToken
        case eligible
        case reason
        case currentPlan
        case products
    }

    /// Decodes the response; a missing `products` list (an ineligible
    /// account) decodes as empty instead of failing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appAccountToken = try container.decode(UUID.self, forKey: .appAccountToken)
        eligible = try container.decode(Bool.self, forKey: .eligible)
        reason = try container.decodeIfPresent(BillingIneligibilityReason.self, forKey: .reason)
        currentPlan = try container.decode(BillingCurrentPlan.self, forKey: .currentPlan)
        products = try container.decodeIfPresent([BillingProductReference].self, forKey: .products) ?? []
    }
}
