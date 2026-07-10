import Foundation

extension AgentHibernationController {
    struct InFlightTeardown: Sendable {
        let requestID: UUID
    }
}
