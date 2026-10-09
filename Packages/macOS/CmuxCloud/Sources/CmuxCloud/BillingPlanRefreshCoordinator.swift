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
    private var nextGeneration: UInt64 = 0
    private var pendingRequestGenerations: [UUID: UInt64] = [:]
    private var latestAppliedGeneration: UInt64 = 0

    /// Creates an empty coordinator.
    public init() {}

    /// Starts a request for `scope`, retaining a same-scope confirmed answer.
    public mutating func begin(scope: BillingPlanRefreshScope) -> UUID {
        if self.scope != scope {
            self.scope = scope
            state = .unknown
            nextGeneration = 0
            pendingRequestGenerations.removeAll()
            latestAppliedGeneration = 0
        }
        let requestID = UUID()
        nextGeneration &+= 1
        pendingRequestGenerations[requestID] = nextGeneration
        return requestID
    }

    /// Invalidates the retained answer when the confirmed account/team scope
    /// no longer matches the answer's scope.
    public mutating func invalidateIfScopeChanged(accountID: String?, teamID: String?) {
        guard let scope else { return }
        guard scope.accountID == accountID, scope.teamID == teamID else {
            reset()
            return
        }
    }

    /// Returns whether a response still belongs to the current scope.
    ///
    /// Multiple windows may refresh the same scope concurrently. Each request
    /// remains valid until it reports, while the generation guard below makes
    /// the newest successful answer win over an older one.
    public func isCurrent(_ requestID: UUID, scope: BillingPlanRefreshScope) -> Bool {
        self.scope == scope && pendingRequestGenerations[requestID] != nil
    }

    /// Discards a request that was cancelled before it produced a response.
    public mutating func discard(_ requestID: UUID, scope: BillingPlanRefreshScope) {
        guard self.scope == scope else { return }
        pendingRequestGenerations.removeValue(forKey: requestID)
    }

    /// Stores a successful response for the request's scope.
    public mutating func applySuccess(
        _ requestID: UUID,
        scope: BillingPlanRefreshScope,
        isPro: Bool,
        canManageBilling: Bool
    ) {
        guard let generation = consumeGeneration(requestID, scope: scope),
              generation >= latestAppliedGeneration else { return }
        latestAppliedGeneration = generation
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
        guard let generation = consumeGeneration(requestID, scope: scope),
              generation >= latestAppliedGeneration else { return }
        // A failure must not advance the applied generation: an overlapping
        // older success may still be the first confirmed answer for this
        // scope, and should win over a later request that failed transiently.
        state = state.applyingFailure(for: scope.accountID, teamID: scope.teamID)
    }

    /// Clears an answer after the server explicitly says the session is not
    /// authenticated.
    public mutating func applyUnauthenticated(
        _ requestID: UUID,
        scope: BillingPlanRefreshScope
    ) {
        guard let generation = consumeGeneration(requestID, scope: scope),
              generation >= latestAppliedGeneration else { return }
        latestAppliedGeneration = generation
        state = .unknown
    }

    /// Drops all scope and request state, such as on sign-out.
    public mutating func reset() {
        scope = nil
        nextGeneration = 0
        pendingRequestGenerations.removeAll()
        latestAppliedGeneration = 0
        state = .unknown
    }

    private mutating func consumeGeneration(
        _ requestID: UUID,
        scope: BillingPlanRefreshScope
    ) -> UInt64? {
        guard self.scope == scope else { return nil }
        return pendingRequestGenerations.removeValue(forKey: requestID)
    }
}
