import Foundation

extension SharedLiveAgentIndex {
    static func hookEventReloadInterval(liveAgentCount: Int) -> TimeInterval {
        let clampedAgentCount = max(0, liveAgentCount)
        let intervalSteps = max(
            1,
            (clampedAgentCount + liveAgentsPerReloadIntervalStep - 1) / liveAgentsPerReloadIntervalStep
        )
        return min(
            maxEventReloadInterval,
            TimeInterval(intervalSteps) * minEventReloadInterval
        )
    }

    enum RefreshFreshness: Equatable {
        case joinCurrentGeneration
        case captureAfterRequest
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
