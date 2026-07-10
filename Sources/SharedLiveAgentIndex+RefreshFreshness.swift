import Foundation

extension SharedLiveAgentIndex {
    enum RefreshFreshness: Equatable {
        case joinCurrentGeneration
        case captureAfterRequest
    }
}
