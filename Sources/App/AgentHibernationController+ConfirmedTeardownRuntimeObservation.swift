import Foundation

extension AgentHibernationController {
    struct ConfirmedTeardownRuntimeObservation: Sendable {
        let hasLiveSurface: Bool
        let fingerprint: String?
    }

    typealias ConfirmedTeardownRuntimeObservationProvider = @MainActor @Sendable (
        AgentHibernationRecord
    ) -> ConfirmedTeardownRuntimeObservation
}
