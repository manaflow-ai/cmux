enum ComputerUseReboundHelperProfileReconciliation: Equatable {
    case unchanged
    case noListeningPeer
    case ownedPeer(AgentPIDProcessIdentity)
    case blocked
}
