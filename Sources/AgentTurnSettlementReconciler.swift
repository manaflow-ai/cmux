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
        let expectedGeneration: AgentPIDProcessIdentity? = if let expectedStartSeconds,
            let expectedStartMicroseconds {
            AgentPIDProcessIdentity(
                pid: processID,
                startSeconds: expectedStartSeconds,
                startMicroseconds: expectedStartMicroseconds
            )
        } else {
            nil
        }
        return reconcile(
            currentGeneration: currentGeneration,
            expectedGeneration: expectedGeneration,
            processPresence: PIDPresence.current(pid: processID)
        )
    }

    /// Reconciles independently observed identity and presence evidence.
    static func reconcile(
        currentGeneration: AgentPIDProcessIdentity?,
        expectedGeneration: AgentPIDProcessIdentity?,
        processPresence: PIDPresence
    ) -> Self {
        if processPresence == .absent {
            return .exited
        }
        if let expectedGeneration, let currentGeneration {
            return currentGeneration == expectedGeneration
                ? .live
                : .exited
        }
        if currentGeneration != nil {
            return .live
        }
        return .unknown
    }
}
