import Foundation

extension SharedLiveAgentIndex.RefreshGeneration {
    enum Phase: Equatable {
        case queued
        case capturing
        case timedOut
    }
}
