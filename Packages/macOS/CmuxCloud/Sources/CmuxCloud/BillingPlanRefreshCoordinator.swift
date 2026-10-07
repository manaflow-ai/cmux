import Foundation

/// The account and team scope for one billing-plan answer.
public struct BillingPlanRefreshScope: Sendable, Equatable {
    /// The signed-in account whose entitlement is being refreshed.
    public let accountID: String
    /// The confirmed active team, or `nil` for the personal scope.
    public let teamID: String?

    /// Creates a billing refresh scope.
    public init(accountID: String, teamID: String?) {
        self.accountID = accountID
        self.teamID = teamID
    }
}

/// Owns the scope and stale-response rules for billing-plan refreshes.
///
/// The app adapter supplies credentials and performs I/O, while this value
/// keeps a confirmed answer during transient failures and rejects results from
/// an older account, team, or request.
public struct BillingPlanRefreshCoordinator: Sendable {
    /// The most recent confirmed answer, or unknown before the first answer.
    public private(set) var state = BillingPlanState.unknown

    private var scope: BillingPlanRefreshScope?
    private var requestID: UUID?

    /// Creates an empty coordinator.
    public init() {}

    /// Starts a request for `scope`, retaining a same-scope confirmed answer.
    public mutating func begin(scope: BillingPlanRefreshScope) -> UUID {
        if self.scope != scope {
            self.scope = scope
            state = .unknown
        }
        let requestID = UUID()
        self.requestID = requestID
        if state.accountID != scope.accountID || state.teamID != scope.teamID {
            state = .unknown
        }
        return requestID
    }

    /// Invalidates the retained answer when the confirmed account/team scope
    /// no longer matches the answer's scope.
    public mutating func invalidateIfScopeChanged(accountID: String?, teamID: String?) {
        guard let scope else { return }
        guard scope.accountID == accountID, scope.teamID == teamID else {
            reset()
        }
    }

    /// Returns whether a response still belongs to the current request.
    public func isCurrent(_ requestID: UUID, scope: BillingPlanRefreshScope) -> Bool {
        self.requestID == requestID && self.scope == scope
    }

    /// Stores a successful response for the request's scope.
    public mutating func applySuccess(
        _ requestID: UUID,
        scope: BillingPlanRefreshScope,
        isPro: Bool,
        canManageBilling: Bool
    ) {
        guard isCurrent(requestID, scope: scope) else { return }
        state = state.applyingSuccess(
            for: scope.accountID,
            teamID: scope.teamID,
            isPro: isPro,
            canManageBilling: canManageBilling
        )
    }

    /// Retains a same-scope answer after a transient request failure.
    public mutating func applyTransientFailure(
        _ requestID: UUID,
        scope: BillingPlanRefreshScope
    ) {
        guard isCurrent(requestID, scope: scope) else { return }
        state = state.applyingFailure(for: scope.accountID, teamID: scope.teamID)
    }

    /// Clears an answer after the server explicitly says the session is not
    /// authenticated.
    public mutating func applyUnauthenticated(
        _ requestID: UUID,
        scope: BillingPlanRefreshScope
    ) {
        guard isCurrent(requestID, scope: scope) else { return }
        state = .unknown
    }

    /// Drops all scope and request state, such as on sign-out.
    public mutating func reset() {
        requestID = nil
        scope = nil
        state = .unknown
    }
}
