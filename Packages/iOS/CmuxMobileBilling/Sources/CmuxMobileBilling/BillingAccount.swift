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
    /// The catalog family selected by the billing backend.
    /// When nil, infer it from the current plan or products for compatibility
    /// with older wire responses.
    public let catalogFamily: BillingPlanFamily?

    /// Creates an account value.
    /// - Parameters:
    ///   - appAccountToken: The server-minted purchase token.
    ///   - eligible: Whether App Store purchases are allowed.
    ///   - reason: Why purchases are not allowed, when they are not.
    ///   - currentPlan: The current plan.
    ///   - products: The products on sale.
    ///   - catalogFamily: Explicit family for accounts with no current plan or products.
    public init(
        appAccountToken: UUID,
        eligible: Bool,
        reason: BillingIneligibilityReason?,
        currentPlan: BillingCurrentPlan,
        products: [BillingProductReference],
        catalogFamily: BillingPlanFamily? = nil
    ) {
        self.appAccountToken = appAccountToken
        self.eligible = eligible
        self.reason = reason
        self.currentPlan = currentPlan
        self.products = products
        self.catalogFamily = catalogFamily
    }

    /// The paid plans the plans screen describes when this build sells none
    /// (an ineligible account gets no products): the plans this package's app
    /// sells, inferred from the current or on-sale plan family, plus any plan
    /// from the other family only when the account is on it or it is on sale,
    /// smallest first.
    /// Without these an ineligible account, such as every TestFlight and dev
    /// build in production, saw a plans screen with no plans on it.
    public var catalogPlanIDs: [BillingPlanID] {
        let sellsNext = catalogFamily.map { $0 == .next }
            ?? (currentPlan.planID.isNext || products.contains { $0.planID.isNext })
        var plans: Set<BillingPlanID> = sellsNext
            ? [.nextPlus, .nextPro, .nextMax]
            : [.pro, .max]
        plans.formUnion(products.map(\.planID).filter { $0.rank > 0 })
        if currentPlan.planID.rank > 0 { plans.insert(currentPlan.planID) }
        return plans.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case appAccountToken
        case eligible
        case reason
        case currentPlan
        case products
        case catalogFamily
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
        catalogFamily = try container.decodeIfPresent(BillingPlanFamily.self, forKey: .catalogFamily)
    }
}
