import Dispatch

/// One exact process generation and its one-shot exit delivery.
@MainActor
struct AgentProcessExitObservation {
    let generation: AgentPIDProcessIdentity
    let source: DispatchSourceProcess
    let onExit: @MainActor (String, AgentPIDProcessIdentity) -> Void
}
