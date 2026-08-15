import Darwin
import Foundation

/// One refreshed process generation observed after hibernation commits.
struct AgentHibernationProcessExitEpoch: Sendable {
    let terminations: [AgentHibernationController.ScopedProcessTermination]
    let processGroupLeaders: [pid_t: AgentPIDProcessIdentity]
    let signalableProcessIdentities: Set<AgentPIDProcessIdentity>

    init(
        terminations: [AgentHibernationController.ScopedProcessTermination],
        processGroupLeaders: [pid_t: AgentPIDProcessIdentity],
        signalableProcessIdentities: Set<AgentPIDProcessIdentity> = []
    ) {
        self.terminations = terminations
        self.processGroupLeaders = processGroupLeaders
        self.signalableProcessIdentities = signalableProcessIdentities
    }
}
