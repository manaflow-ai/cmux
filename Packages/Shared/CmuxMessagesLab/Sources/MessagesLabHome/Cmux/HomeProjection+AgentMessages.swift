import CmuxHomeCore

/// The Chief's messages to its agents and their reports fold into one row per answer
/// (HomeAgentMessages); a click on that row's link expands or collapses it. HomeStore keeps which
/// folds are open; the projection only forwards the click.
extension HomeProjection {
    /// A fold row's click: HomeStore expands or collapses it and the transcript follows.
    func toggleAgentMessages(_ group: String) {
        guard !stopped else { return }
        homeStore.toggleAgentMessages(group, in: conversation)
    }
}
