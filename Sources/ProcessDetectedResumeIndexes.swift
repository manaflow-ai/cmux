import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    init(
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) {
        self.restorableAgentIndex = restorableAgentIndex
        self.surfaceResumeBindingIndex = surfaceResumeBindingIndex
    }

    init(_ loadResult: SharedLiveAgentIndexLoader.LoadResult) {
        self.init(
            restorableAgentIndex: loadResult.index,
            surfaceResumeBindingIndex: loadResult.surfaceResumeBindingIndex
        )
    }

    @MainActor
    static func load(
        maximumAge: TimeInterval = 60
    ) async -> ProcessDetectedResumeIndexes? {
        await load(coordinatedBy: .shared, maximumAge: maximumAge)
    }

    @MainActor
    static func load(
        coordinatedBy sharedIndex: SharedLiveAgentIndex,
        maximumAge: TimeInterval = 60
    ) async -> ProcessDetectedResumeIndexes? {
        await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: maximumAge)
    }
}
