import Foundation

extension AgentHibernationController {
    struct Confirmation: Sendable {
        let fingerprint: String
        let sampledAt: TimeInterval
        let dueAt: TimeInterval
    }
}
