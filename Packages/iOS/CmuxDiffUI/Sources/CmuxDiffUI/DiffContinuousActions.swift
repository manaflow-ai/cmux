import CmuxMobileRPC

struct DiffContinuousActions: Sendable {
    let loadFile: @MainActor @Sendable (String, Bool) -> Void
    let expandContext: @MainActor @Sendable (DiffContextExpansionRequest) -> Void
    let toggleViewed: @MainActor @Sendable (String) -> Void
    let toggleCollapsed: @MainActor @Sendable (String) -> Void
    let collapseAll: @MainActor @Sendable () -> Void
    let selectBase: @MainActor @Sendable (MobileDiffBaseKind) -> Void
    let setIgnoreWhitespace: @MainActor @Sendable (Bool) -> Void
    let openQuickNote: @MainActor @Sendable (DiffQuickNoteTarget) -> Void
    let quickNoteAvailable: Bool
    let refresh: @MainActor @Sendable () async -> Void
}
