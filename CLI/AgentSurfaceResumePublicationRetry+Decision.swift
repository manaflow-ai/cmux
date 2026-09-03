import Foundation

extension AgentSurfaceResumePublicationRetry {
    enum Decision {
        case alreadyApplied
        case retry(params: [String: Any])
        case superseded
    }
}
