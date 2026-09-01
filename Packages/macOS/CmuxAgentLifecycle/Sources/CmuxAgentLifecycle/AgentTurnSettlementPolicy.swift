/// The integration-specific boundary required for normal settlement.
public nonisolated enum AgentTurnSettlementPolicy: Sendable {
    /// A turn-end boundary is authoritative after structured work drains.
    case turnEndWhenNoBackgroundWork
    /// The integration must emit an explicit settled boundary after work drains.
    case requiresSettledBoundary
}
