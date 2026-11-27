import Foundation

extension AgentHibernationController {
    struct UnableToProtectMarker: Sendable {
        let fingerprint: String
        let lastActivityAt: TimeInterval
        let retryAfter: TimeInterval
    }
}
