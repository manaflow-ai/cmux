import Foundation

extension SharedLiveAgentIndex {
    struct RefreshGeneration {
        let id: UUID
        let ordinal: UInt64
        var phase: Phase
        var publication: RefreshPublication
        var validationPanelsByPanelID: [UUID: RestorableAgentSessionIndex.PanelKey]
        var cachedResultToValidate: LoadResult? = nil
    }
}
