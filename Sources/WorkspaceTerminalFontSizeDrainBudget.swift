/// Per-turn bounds for workspace terminal font-size processing.
struct WorkspaceTerminalFontSizeDrainBudget {
    static let maximumPanelVisitsPerDrain = 8
    static let maximumLiveActionsPerDrain = 8
    static let maximumRequestVisitsPerDrain = 8

    private(set) var panelVisitCount = 0
    private(set) var liveActionUpperBound = 0
    private(set) var requestVisitCount = 0

    mutating func reserve(
        panelHasLiveSurface: Bool,
        nativeActionUpperBound: Int
    ) -> Bool {
        guard nativeActionUpperBound >= 0,
              panelVisitCount < Self.maximumPanelVisitsPerDrain,
              !panelHasLiveSurface
                || liveActionUpperBound + nativeActionUpperBound
                    <= Self.maximumLiveActionsPerDrain else {
            return false
        }
        panelVisitCount += 1
        if panelHasLiveSurface {
            liveActionUpperBound += nativeActionUpperBound
        }
        return true
    }

    mutating func reservePanelVisit() -> Bool {
        guard panelVisitCount < Self.maximumPanelVisitsPerDrain else {
            return false
        }
        panelVisitCount += 1
        return true
    }

    mutating func reserveLiveActions(_ nativeActionUpperBound: Int) -> Bool {
        guard nativeActionUpperBound >= 0,
              liveActionUpperBound + nativeActionUpperBound
                <= Self.maximumLiveActionsPerDrain else {
            return false
        }
        liveActionUpperBound += nativeActionUpperBound
        return true
    }

    mutating func reserveRequestVisit() -> Bool {
        guard requestVisitCount < Self.maximumRequestVisitsPerDrain else {
            return false
        }
        requestVisitCount += 1
        return true
    }
}
