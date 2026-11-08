enum PromotionWorkspaceRace: CaseIterable, Sendable {
    case eventRefresh
    case stateSyncProjection
    case eventRefreshFailure
}
