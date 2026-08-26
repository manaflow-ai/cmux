import Foundation

extension AgentHibernationController {
    struct Confirmation: Sendable {
        let trigger: AgentHibernationReclaimTrigger
        let fingerprint: String
        let processIdentities: [Int: AgentPIDProcessIdentity]
        let sampledAt: TimeInterval
        let dueAt: TimeInterval
    }
}
