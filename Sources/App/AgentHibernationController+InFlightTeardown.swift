import Foundation

extension AgentHibernationController {
    struct InFlightTeardown: Sendable {
        let requestID: UUID
        let trigger: AgentHibernationReclaimTrigger
    }

}
