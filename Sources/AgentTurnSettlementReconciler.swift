import CmuxAgentLifecycle
import Darwin

typealias AgentTurnBoundary = CmuxAgentLifecycle.AgentTurnBoundary
typealias AgentTurnProcessLiveness =
    CmuxAgentLifecycle.AgentTurnProcessLiveness
typealias AgentTurnFreshness = CmuxAgentLifecycle.AgentTurnFreshness
typealias AgentTurnSettlementEvidence =
    CmuxAgentLifecycle.AgentTurnSettlementEvidence
typealias AgentTurnSettlementDecision =
    CmuxAgentLifecycle.AgentTurnSettlementDecision
typealias AgentTurnSettlementPolicy =
    CmuxAgentLifecycle.AgentTurnSettlementPolicy
typealias AgentTurnSettlementReconciler =
    CmuxAgentLifecycle.AgentTurnSettlementReconciler

extension AgentTurnProcessLiveness {
    /// Reads process liveness through the shared privilege-safe generation reader.
    static func observe(
        pid: Int?,
        expectedStartSeconds: Int64? = nil,
        expectedStartMicroseconds: Int64? = nil
    ) -> Self {
        guard let pid,
              pid > 0,
              pid <= Int(Int32.max) else {
            return .unknown
        }
        let processID = pid_t(pid)
        let currentGeneration = AgentPIDProcessIdentity(pid: processID)
        if let expectedStartSeconds, let expectedStartMicroseconds {
            let expectedGeneration = AgentPIDProcessIdentity(
                pid: processID,
                startSeconds: expectedStartSeconds,
                startMicroseconds: expectedStartMicroseconds
            )
            return currentGeneration == expectedGeneration ? .live : .exited
        }
        return currentGeneration == nil ? .exited : .live
    }
}
