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
    /// The server-assigned paywall configuration; nil when the server sent
    /// none or an invalid one (the app then shows
    /// ``BillingPaywallConfig/control``).
    public let paywall: BillingPaywallConfig?
    /// The free trial the server may grant after a device proof; nil when
    /// it offers none.
    public let trial: BillingTrialOffer?
    /// True for cmux staff accounts; shows the Paywall Lab.
    public let staff: Bool
    /// The server's pricing facts per plan id; empty when it sent none.
    public let planFacts: [String: BillingPlanFacts]

    /// Creates an account value.
    /// - Parameters:
    ///   - appAccountToken: The server-minted purchase token.
    ///   - eligible: Whether App Store purchases are allowed.
    ///   - reason: Why purchases are not allowed, when they are not.
    ///   - currentPlan: The current plan.
    ///   - products: The products on sale.
    ///   - paywall: The server's paywall configuration, when it sent one.
    public init(
        appAccountToken: UUID,
        eligible: Bool,
        reason: BillingIneligibilityReason?,
        currentPlan: BillingCurrentPlan,
        products: [BillingProductReference],
        paywall: BillingPaywallConfig? = nil,
        trial: BillingTrialOffer? = nil,
        staff: Bool = false,
        planFacts: [String: BillingPlanFacts] = [:]
    ) {
        self.appAccountToken = appAccountToken
        self.eligible = eligible
        self.reason = reason
        self.currentPlan = currentPlan
        self.products = products
        self.paywall = paywall
        self.trial = trial
        self.staff = staff
        self.planFacts = planFacts
    }

    enum CodingKeys: String, CodingKey {
        case appAccountToken
        case eligible
        case reason
        case currentPlan
        case products
        case paywall
        case trial
        case staff
        case planFacts
    }

    /// Decodes the response; a missing `products` list (an ineligible
    /// account) decodes as empty instead of failing, and a missing or
    /// invalid `paywall` object decodes as nil instead of failing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appAccountToken = try container.decode(UUID.self, forKey: .appAccountToken)
        eligible = try container.decode(Bool.self, forKey: .eligible)
        reason = try container.decodeIfPresent(BillingIneligibilityReason.self, forKey: .reason)
        currentPlan = try container.decode(BillingCurrentPlan.self, forKey: .currentPlan)
        products = try container.decodeIfPresent([BillingProductReference].self, forKey: .products) ?? []
        paywall = try? container.decodeIfPresent(BillingPaywallConfig.self, forKey: .paywall)
        trial = try? container.decodeIfPresent(BillingTrialOffer.self, forKey: .trial)
        staff = (try? container.decodeIfPresent(Bool.self, forKey: .staff)) == true
        planFacts = (try? container.decodeIfPresent([String: BillingPlanFacts].self, forKey: .planFacts)) ?? [:]
    }
}
