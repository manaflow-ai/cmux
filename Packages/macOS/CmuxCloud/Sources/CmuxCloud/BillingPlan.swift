import Foundation

/// The account-scoped billing entitlement used by Cloud access controls.
public struct BillingPlanState: Sendable, Equatable {
    /// The account whose entitlement is known, or `nil` while unknown.
    public let accountID: String?
    /// The confirmed team whose entitlement is known, or `nil` for personal scope.
    public let teamID: String?
    /// Whether the known account includes Cloud access.
    public let isPro: Bool
    /// Whether the known account can manage billing through the hosted portal.
    public let canManageBilling: Bool

    /// Creates an entitlement snapshot.
    ///
    /// - Parameters:
    ///   - accountID: The account owning the snapshot, or `nil` when unknown.
    ///   - teamID: The confirmed team owning the snapshot, or `nil` for personal scope.
    ///   - isPro: Whether the account includes Cloud access.
    ///   - canManageBilling: Whether billing can be managed in the hosted portal.
    public init(accountID: String?, teamID: String? = nil, isPro: Bool, canManageBilling: Bool) {
        self.accountID = accountID
        self.teamID = teamID
        self.isPro = isPro
        self.canManageBilling = canManageBilling
    }

    /// An unknown entitlement that must not be treated as a free plan.
    public static var unknown: Self { Self(accountID: nil, isPro: false, canManageBilling: false) }

    /// Applies a successful response to the account that requested it.
    public func applyingSuccess(
        for accountID: String,
        teamID: String? = nil,
        isPro: Bool,
        canManageBilling: Bool
    ) -> Self {
        Self(accountID: accountID, teamID: teamID, isPro: isPro, canManageBilling: canManageBilling)
    }

    /// Retains an existing answer for the same account and confirmed team.
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
    public func fetch(
        from url: URL,
        accessToken: String?,
        refreshToken: String? = nil,
        teamID: String? = nil
    ) async throws -> BillingPlanDetails {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if let teamID {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "teamId", value: teamID)
            ]
        }
        guard let requestURL = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL)
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
        // A missing token receives a successful Free response from the endpoint
        // for compatibility. Never accept that anonymous response as the
        // signed-in account's entitlement.
        guard decoded.authenticated == true else {
            throw URLError(.userAuthenticationRequired)
        }
        // The server's no-argument route may choose a paid team as a fallback.
        // Explicit requests must prove that the response is for that team.
        guard decoded.teamID == teamID else {
            throw URLError(.cannotParseResponse)
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
        return BillingPlanDetails(isPro: isPro, canManageBilling: canManageBilling)
    }

    private let session: URLSession

    private struct Response: Decodable {
        let authenticated: Bool?
        let teamID: String?
        let isPro: Bool?
        let planId: String?
        let billingManagement: String?
        let teamPlanId: String?
        let teamBillingManagement: String?

        private enum CodingKeys: String, CodingKey {
            case authenticated
            case teamID = "teamId"
            case isPro
            case planId
            case billingManagement
            case teamPlanId
            case teamBillingManagement
        }
    }
}
