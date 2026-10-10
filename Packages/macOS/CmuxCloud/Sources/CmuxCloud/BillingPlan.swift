import Foundation

/// The account-scoped billing entitlement used by Cloud access controls.
public struct BillingPlanState: Sendable, Equatable {
    /// The account whose entitlement is known, or `nil` while unknown.
    public let accountID: String?
    /// The active team whose entitlement is known, or `nil` for a personal scope.
    public let teamID: String?
    /// Whether the known account includes Cloud access.
    public let isPro: Bool
    /// Whether the known account can manage billing through the hosted portal.
    public let canManageBilling: Bool

    /// Creates an entitlement snapshot.
    ///
    /// - Parameters:
    ///   - accountID: The account owning the snapshot, or `nil` when unknown.
    ///   - teamID: The active team owning the snapshot, or `nil` for a personal scope.
    ///   - isPro: Whether the account includes Cloud access.
    ///   - canManageBilling: Whether billing can be managed in the hosted portal.
    public init(accountID: String?, teamID: String? = nil, isPro: Bool, canManageBilling: Bool) {
        self.accountID = accountID
        self.teamID = teamID
        self.isPro = isPro
        self.canManageBilling = canManageBilling
    }

    /// An unknown entitlement that must not be treated as a free plan.
    public static var unknown: Self { Self(accountID: nil, teamID: nil, isPro: false, canManageBilling: false) }

    /// Applies a successful response to the account that requested it.
    public func applyingSuccess(
        for accountID: String,
        teamID: String? = nil,
        isPro: Bool,
        canManageBilling: Bool
    ) -> Self {
        Self(accountID: accountID, teamID: teamID, isPro: isPro, canManageBilling: canManageBilling)
    }

    /// Retains an existing answer for the same account and clears other answers.
    public func applyingFailure(for accountID: String, teamID: String? = nil) -> Self {
        self.accountID == accountID && self.teamID == teamID ? self : .unknown
    }
}

/// The decoded billing response returned by the Cloud service.
public struct BillingPlanDetails: Sendable, Equatable {
    /// Whether the account includes Cloud access.
    public let isPro: Bool
    /// Whether the account can manage billing through the hosted portal.
    public let canManageBilling: Bool

    /// Creates decoded billing details.
    public init(isPro: Bool, canManageBilling: Bool) {
        self.isPro = isPro
        self.canManageBilling = canManageBilling
    }
}

/// Errors that carry entitlement-specific meaning to the account flow.
public enum BillingPlanClientError: Error, Equatable, Sendable {
    /// The endpoint returned its unauthenticated fallback payload.
    case unauthenticated
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
    @concurrent
    public func fetch(from url: URL, accessToken: String?, refreshToken: String? = nil) async throws -> BillingPlanDetails {
        let scopedResponse = try await fetchResponse(
            from: url,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
        guard scopedResponse.authenticated else {
            throw BillingPlanClientError.unauthenticated
        }

        // An explicit team request intentionally returns only that team's
        // billing fields. Read the personal response as well so a personal Pro
        // subscription still grants Pro while the selected team is free.
        let isExplicitTeamRequest = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains { $0.name == "teamId" } == true
        let personalResponse: Response?
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           isExplicitTeamRequest {
            components.queryItems?.removeAll { $0.name == "teamId" }
            if components.queryItems?.isEmpty == true {
                components.queryItems = nil
            }
            guard let personalURL = components.url else { throw URLError(.badURL) }
            let response = try await fetchResponse(
                from: personalURL,
                accessToken: accessToken,
                refreshToken: refreshToken
            )
            guard response.authenticated else {
                throw BillingPlanClientError.unauthenticated
            }
            personalResponse = response
        } else {
            personalResponse = nil
        }

        let personalIsPro = personalResponse.map { isPro($0, includeTeam: false) }
            ?? isPro(scopedResponse, includeTeam: false)
        let teamIsPro = isPro(scopedResponse)
        let personalCanManageBilling = personalResponse.map { $0.billingManagement == "stripe" }
            ?? (scopedResponse.billingManagement == "stripe")
        // The unscoped response also carries the implicit team's admin access,
        // but this result is still a personal-scope entitlement. Treating that
        // team-only flag as personal billing management makes a free team admin
        // open the Stripe portal instead of the personal upgrade flow.
        let teamCanManageBilling = (isExplicitTeamRequest && scopedResponse.canManageBilling == true)
            || scopedResponse.teamBillingManagement == "stripe"
        return BillingPlanDetails(
            isPro: personalIsPro || teamIsPro,
            canManageBilling: personalCanManageBilling || teamCanManageBilling
        )
    }

    private func fetchResponse(
        from url: URL,
        accessToken: String?,
        refreshToken: String?
    ) async throws -> Response {
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
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func isPro(_ response: Response, includeTeam: Bool = true) -> Bool {
        // The default endpoint returns both personal and active-team plans.
        // A paid team grants Cloud access even when the personal subscription
        // is free, which is the normal path for team-owned machines.
        let paidPlanIDs = ["go", "pro", "max", "team", "founders"]
        return response.isPro == true
            || paidPlanIDs.contains(response.planId?.lowercased() ?? "")
            || paidPlanIDs.contains(response.subscriptionPlanId?.lowercased() ?? "")
            || (includeTeam && paidPlanIDs.contains(response.teamPlanId?.lowercased() ?? ""))
    }

    private let session: URLSession

    private struct Response: Decodable {
        let authenticated: Bool
        let isPro: Bool?
        let planId: String?
        let billingManagement: String?
        let canManageBilling: Bool?
        let teamPlanId: String?
        let teamBillingManagement: String?
        let subscriptionPlanId: String?
    }
}
