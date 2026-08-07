/// The lifecycle mutation permitted by settlement reconciliation.
public nonisolated enum AgentTurnSettlementDecision: Equatable, Sendable {
    /// Preserve running state because completion is not yet authoritative.
    case keepRunning
    /// Publish normal settled or idle behavior.
    case settle
    /// Retire the exact turn while preserving the process's running lifecycle.
    case settleTurnKeepingProcessRunning
    /// Retire the dead process without publishing a successful completion.
    case terminateWithoutCompletion
}
