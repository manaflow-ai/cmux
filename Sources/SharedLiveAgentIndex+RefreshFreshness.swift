import Foundation

extension SharedLiveAgentIndex {
    static func hookEventReloadInterval(
        liveAgentCount: Int,
        indexedSessionCount: Int
    ) -> TimeInterval {
        let workloadCount = max(0, max(liveAgentCount, indexedSessionCount))
        let intervalSteps = max(
            1,
            (workloadCount + workloadUnitsPerReloadIntervalStep - 1) / workloadUnitsPerReloadIntervalStep
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
