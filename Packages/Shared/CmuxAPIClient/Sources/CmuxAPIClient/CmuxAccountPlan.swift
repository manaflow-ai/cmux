/// The authenticated account and its resolved billing plan, as returned by
/// ``CmuxAPIClient/accountMe()``. Mirrors the `account.me` OpenAPI response.
public struct CmuxAccountPlan: Sendable, Hashable {
    /// Stack user id of the signed-in account.
    public var userID: String
    /// Primary email, or the empty string when the Stack user has none.
    public var email: String
    /// Resolved plan identifier, currently `"free"` or `"pro"`.
    public var planID: String
    /// Whether the account has an active Pro entitlement.
    public var isPro: Bool
    /// How billing is managed for this account: `"stripe"`, `"external"`, or `"none"`.
    public var billingManagement: String

    /// Creates an account plan snapshot.
    /// - Parameters:
    ///   - userID: Stack user id of the signed-in account.
    ///   - email: Primary email, or the empty string when there is none.
    ///   - planID: Resolved plan identifier (`"free"` or `"pro"`).
    ///   - isPro: Whether the account has an active Pro entitlement.
    ///   - billingManagement: `"stripe"`, `"external"`, or `"none"`.
    public init(
        userID: String,
        email: String,
        planID: String,
        isPro: Bool,
        billingManagement: String
    ) {
        self.userID = userID
        self.email = email
        self.planID = planID
        self.isPro = isPro
        self.billingManagement = billingManagement
    }
}
