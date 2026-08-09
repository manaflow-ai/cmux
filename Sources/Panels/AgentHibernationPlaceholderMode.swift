enum AgentHibernationPlaceholderMode: Equatable {
    case hibernated
    /// User-initiated sleep. Distinct from `hibernated` because it is shown
    /// even while the panel is visible: manual sleep waits for an explicit
    /// wake instead of resuming on visit.
    case sleeping
    case recovering
    case failed
}
