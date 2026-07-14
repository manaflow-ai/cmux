import Foundation

extension SharedLiveAgentIndex {
    struct RefreshRequest {
        let generationID: UUID?
        let task: Task<LoadResult?, Never>
        let processMetadataCapture: SharedLiveAgentIndexProcessMetadataBoundary
    }
}
