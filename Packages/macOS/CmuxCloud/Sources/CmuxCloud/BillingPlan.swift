import CMUXMobileCore
import Foundation

/// The account-scoped billing entitlement used by Cloud access controls.
public struct BillingPlanState: Sendable, Equatable {
    /// The account whose entitlement is known, or `nil` while unknown.
    public let accountID: String?
    /// Whether the known account includes Cloud access.
    public let isPro: Bool
    /// Whether the known account can manage billing through the hosted portal.
    public let canManageBilling: Bool
    /// The known account's effective tier, or `nil` while unknown.
    public let tier: CmuxPlanTier?
    /// The Pro free trial that sets the tier, or `nil` when there is none.
    public let proTrial: CmuxProTrial?

    /// Creates an entitlement snapshot.
    ///
    /// - Parameters:
    ///   - accountID: The account owning the snapshot, or `nil` when unknown.
    ///   - isPro: Whether the account includes Cloud access.
    ///   - canManageBilling: Whether billing can be managed in the hosted portal.
    ///   - tier: The effective tier. Defaults to Pro or Free from `isPro`
    ///     for callers that only know the legacy flag.
    ///   - proTrial: The Pro free trial that sets the tier, if any.
    public init(
        accountID: String?,
        isPro: Bool,
        canManageBilling: Bool,
        tier: CmuxPlanTier? = nil,
        proTrial: CmuxProTrial? = nil
    ) {
        self.accountID = accountID
        self.isPro = isPro
        self.canManageBilling = canManageBilling
        self.tier = accountID == nil ? nil : (tier ?? (isPro ? .pro : .free))
        self.proTrial = accountID == nil ? nil : proTrial
    }

    /// An unknown entitlement that must not be treated as a free plan.
    public static var unknown: Self { Self(accountID: nil, isPro: false, canManageBilling: false) }

    /// Applies a successful response to the account that requested it.
    public func applyingSuccess(
        for accountID: String,
        isPro: Bool,
        canManageBilling: Bool,
        tier: CmuxPlanTier? = nil,
        proTrial: CmuxProTrial? = nil
    ) -> Self {
        Self(accountID: accountID, isPro: isPro, canManageBilling: canManageBilling, tier: tier, proTrial: proTrial)
    }

    /// Retains an existing answer for the same account and clears other answers.
    public func applyingFailure(for accountID: String) -> Self {
        self.accountID == accountID ? self : .unknown
    }
}

/// The decoded billing response returned by the Cloud service.
public struct BillingPlanDetails: Sendable, Equatable {
    /// Whether the account includes Cloud access.
    public let isPro: Bool
    /// Whether the account can manage billing through the hosted portal.
    public let canManageBilling: Bool
    /// The effective tier: the higher of the personal and active-team plans.
    public let tier: CmuxPlanTier
    /// The personal Pro free trial, or `nil` when there is none or a team
    /// plan of Pro or higher sets the tier instead.
    public let proTrial: CmuxProTrial?

    /// Creates decoded billing details.
    public init(isPro: Bool, canManageBilling: Bool, tier: CmuxPlanTier? = nil, proTrial: CmuxProTrial? = nil) {
        self.isPro = isPro
        self.canManageBilling = canManageBilling
        self.tier = tier ?? (isPro ? .pro : .free)
        self.proTrial = proTrial
    }
}

/// Fetches a billing entitlement without requiring UI isolation.
public struct BillingPlanClient: Sendable {
    /// Creates a client that uses the supplied URL session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches and decodes the entitlement for an authenticated account.
    ///
    /// - Parameters:
    ///   - url: The billing-plan endpoint.
    ///   - accessToken: An optional bearer token.
    ///   - refreshToken: An optional session refresh token.
    /// - Returns: The decoded entitlement details.
    /// - Throws: A URL-loading or decoding error when the request fails.
    public func fetch(from url: URL, accessToken: String?, refreshToken: String? = nil) async throws -> BillingPlanDetails {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let refreshToken {
            request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // The endpoint answers a request it cannot authenticate with a free
        // plan. That says nothing about the signed-in account's entitlement.
        if decoded.authenticated == false {
            throw URLError(.userAuthenticationRequired)
        }
        // The default endpoint returns both personal and active-team plans.
        // A paid team grants Cloud access even when the personal subscription
        // is free, which is the normal path for team-owned machines.
        let paidPlanIDs = ["go", "pro", "max", "team", "founders"]
        let isPro = decoded.isPro == true
            || paidPlanIDs.contains(decoded.planId?.lowercased() ?? "")
            || paidPlanIDs.contains(decoded.teamPlanId?.lowercased() ?? "")
        let canManageBilling = decoded.billingManagement == "stripe"
            || decoded.teamBillingManagement == "stripe"
        // `planId` is "pro" for a Max or Go subscriber; the exact personal
        // plan is in `subscriptionPlanId`. Gating on the tier ordering keeps
        // Max from being offered the Pro upgrade it already includes.
        let tier = CmuxPlanTier.resolved(
            subscriptionPlanID: decoded.subscriptionPlanId,
            planID: decoded.planId,
            teamPlanID: decoded.teamPlanId,
            isPro: decoded.isPro == true
        )
        // A Pro free trial is reported as `subscriptionPlanId: "pro"` with a
        // `trial` object. It names the tier only when no team plan of Pro or
        // higher outranks it; the team plan is then what the person has.
        let teamTier = CmuxPlanTier(planID: decoded.teamPlanId) ?? .free
        let proTrial = decoded.trial.flatMap { trial in
            teamTier.includesPro ? nil : CmuxProTrial(endsAt: CmuxProTrial.endDate(fromISO8601: trial.endsAt))
        }
        return BillingPlanDetails(isPro: isPro, canManageBilling: canManageBilling, tier: tier, proTrial: proTrial)
    }

    private let session: URLSession

    private struct Response: Decodable {
        let authenticated: Bool?
        let isPro: Bool?
        let planId: String?
        let subscriptionPlanId: String?
        let billingManagement: String?
        let teamPlanId: String?
        let teamBillingManagement: String?
        let trial: Trial?
    }

    /// `trial` of the plan response; `limits` is not read because every
    /// surface states the fixed trial allowance in its own copy.
    private struct Trial: Decodable {
        let endsAt: String?
    }
}
