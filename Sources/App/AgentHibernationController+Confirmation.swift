import Foundation

extension AgentHibernationController {
    struct Confirmation: Sendable {
        let trigger: AgentHibernationReclaimTrigger
        let fingerprint: String
        let sampledAt: TimeInterval
        let dueAt: TimeInterval
    }
}
