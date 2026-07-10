import Foundation

extension SharedLiveAgentIndex {
    struct RefreshGeneration {
        let id: UUID
        var phase: Phase
        var publication: RefreshPublication
        var validationPanelsByPanelID: [UUID: RestorableAgentSessionIndex.PanelKey]
    }
}
