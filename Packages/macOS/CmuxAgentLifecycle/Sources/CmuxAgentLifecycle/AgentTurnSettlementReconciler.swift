internal import Foundation

/// Reconciles process, turn-order, boundary, and background-work evidence.
public nonisolated struct AgentTurnSettlementReconciler: Sendable {
    /// Creates a settlement reconciler.
    public init() {}

    /// Resolves the lifecycle decision allowed by the supplied evidence.
    ///
    /// - Parameters:
    ///   - integration: The integration whose settlement policy applies.
    ///   - evidence: The complete observed evidence for the turn boundary.
    /// - Returns: The only lifecycle action that is safe to publish.
    public func resolve(
        integration: BuiltInAgentIntegration,
        evidence: AgentTurnSettlementEvidence
    ) -> AgentTurnSettlementDecision {
        if evidence.turnFreshness == .superseded {
            return .keepRunning
        }
        if evidence.processLiveness == .exited {
            return .terminateWithoutCompletion
        }
        // A missing or unverifiable process generation cannot prove that the
        // boundary came from the live owner. Keep the turn conservative until
        // a later hook supplies reliable live/exited evidence.
        if evidence.processLiveness == .unknown {
            return .keepRunning
        }
        // A boundary without a trustworthy turn identity can belong to an
        // older or newer turn. It must not settle the current session merely
        // because its other evidence looks terminal.
        if evidence.turnFreshness == .unknown {
            return .keepRunning
        }
        if evidence.activeBackgroundWorkCount > 0 {
            return .keepRunning
        }
        if integration.turnSettlementPolicy == .requiresSettledBoundary,
           evidence.boundary != .settled {
            return .keepRunning
        }
        if evidence.activeSiblingTurnCount > 0 {
            return .settleTurnKeepingProcessRunning
        }
        return .settle
    }

    /// Classifies a turn identifier against active, latest, and terminal turn evidence.
    ///
    /// - Parameters:
    ///   - incomingTurnId: The turn identifier carried by the incoming event.
    ///   - activeTurnIds: Exact turn identifiers still active.
    ///   - activeTurnDepth: Legacy nesting depth when exact identifiers are absent.
    ///   - latestTurnId: The most recently observed turn identifier.
    ///   - terminalTurnIds: Turn identifiers already known to be terminal.
    /// - Returns: The strongest freshness classification supported by the evidence.
    public func classifyTurnFreshness(
        incomingTurnId: String?,
        activeTurnIds: [String],
        activeTurnDepth: Int? = nil,
        latestTurnId: String?,
        terminalTurnIds: [String]
    ) -> AgentTurnFreshness {
        guard let incomingTurnId = normalizedTurnId(incomingTurnId) else {
            return .unknown
        }
        let activeTurnIds = Set(activeTurnIds.compactMap(normalizedTurnId))
        let terminalTurnIds = Set(
            terminalTurnIds.compactMap(normalizedTurnId)
        )
        if terminalTurnIds.contains(incomingTurnId) {
            return .superseded
        }
        // A legacy depth can describe more active turns than the exact ID
        // list retained in the record. That partial snapshot cannot establish
        // whether an untracked stop is stale, even when one ID is present.
        if max(0, activeTurnDepth ?? 0) > activeTurnIds.count {
            return .unknown
        }
        if !activeTurnIds.isEmpty {
            return activeTurnIds.contains(incomingTurnId)
                ? .current
                : .superseded
        }
        if let latestTurnId = normalizedTurnId(latestTurnId) {
            return latestTurnId == incomingTurnId
                ? .current
                : .superseded
        }
        return .unknown
    }

    private func normalizedTurnId(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }
}
