import Foundation

/// The account-scoped billing entitlement used by Cloud access controls.
public struct BillingPlanState: Sendable, Equatable {
    /// The account whose entitlement is known, or `nil` while unknown.
    public let accountID: String?
    /// Whether the known account includes Cloud access.
    public let isPro: Bool
    /// Whether the known account can manage billing through the hosted portal.
    public let canManageBilling: Bool

    /// Creates an entitlement snapshot.
    ///
    /// - Parameters:
    ///   - accountID: The account owning the snapshot, or `nil` when unknown.
    ///   - isPro: Whether the account includes Cloud access.
    ///   - canManageBilling: Whether billing can be managed in the hosted portal.
    public init(accountID: String?, isPro: Bool, canManageBilling: Bool) {
        self.accountID = accountID
        self.isPro = isPro
        self.canManageBilling = canManageBilling
    }

    /// An unknown entitlement that must not be treated as a free plan.
    public static var unknown: Self { Self(accountID: nil, isPro: false, canManageBilling: false) }

    /// Applies a successful response to the account that requested it.
    public func applyingSuccess(for accountID: String, isPro: Bool, canManageBilling: Bool) -> Self {
        Self(accountID: accountID, isPro: isPro, canManageBilling: canManageBilling)
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
        return BillingPlanDetails(isPro: decoded.isPro, canManageBilling: decoded.billingManagement == "stripe")
    }

    private let session: URLSession

    private struct Response: Decodable {
        let isPro: Bool
        let billingManagement: String?
    }
}
