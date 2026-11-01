import CmuxHomeCore

/// The Chief's messages to its agents and their reports fold into one row per answer
/// (HomeAgentMessages); a click on that row expands or collapses it. HomeStore keeps which
/// folds are open; the projection only forwards the click.
extension HomeProjection {
    /// A fold row's click: HomeStore expands or collapses it and the transcript follows.
    func toggleAgentMessages(_ group: String) {
        guard !stopped else { return }
        homeStore.toggleAgentMessages(group, in: conversation)
    }

    /// A click on a fold or notes row toggles its group; a click on any other row is not ours.
    func agentRowClicked(_ message: ID) -> Bool {
        guard !stopped, let row = shown.first(where: { HomeMapping.id($0, aliases: aliases) == message })?.agentMessage else {
            return false
        }
        switch row.kind {
        case .fold, .notes: toggleAgentMessages(row.group)
        case .message, .note: return false
        }
        return true
    }
}
