struct DiffContinuousActions: Sendable {
    let loadFile: @MainActor @Sendable (String, Bool) -> Void
    let expandContext: @MainActor @Sendable (DiffContextExpansionRequest) -> Void
    let toggleViewed: @MainActor @Sendable (String) -> Void
    let toggleCollapsed: @MainActor @Sendable (String) -> Void
    let collapseAll: @MainActor @Sendable () -> Void
    let refresh: @MainActor @Sendable () async -> Void
}
