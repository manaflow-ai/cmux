import Foundation

extension SharedLiveAgentIndex {
    struct RefreshGeneration {
        let id: UUID
        let ordinal: UInt64
        var phase: Phase
        var publication: RefreshPublication
        var minimumProcessCaptureStartedAt: Date?
        var validationPanelsByPanelID: [UUID: RestorableAgentSessionIndex.PanelKey]
        var cachedResultToValidate: LoadResult? = nil
        // Authority revision captured when this generation claimed the cached result.
        var cachedResultRevision: UInt64? = nil
    }
}
