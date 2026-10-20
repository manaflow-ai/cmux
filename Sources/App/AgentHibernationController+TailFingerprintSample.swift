import Foundation

extension AgentHibernationController {
    struct TailFingerprintSample: Sendable {
        let fingerprint: String
        let stableSince: TimeInterval
    }
}
