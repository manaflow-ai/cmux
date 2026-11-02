import CmuxHomeCore
import Foundation

/// The Chief's messages to its agents and their reports fold into one row per answer
/// (HomeAgentMessages); a click on that row expands or collapses it. HomeStore keeps which
/// folds are open; the projection only forwards the click.
extension HomeProjection {
    /// A fold row's click: HomeStore expands or collapses it and the transcript follows.
    func toggleAgentMessages(_ group: String) {
        guard !stopped else { return }
        homeStore.toggleAgentMessages(group, in: conversation)
    }

    /// What a click on Feed row `message` opens (``HomeFeedRow/url``); nil for every other row. Any
    /// Feed poster sets the URL, so only the links Home opens elsewhere pass (http, https, mailto,
    /// a cmux app link), as the Feed page refuses other schemes; any other row takes no click.
    func feedRowURL(_ message: ID) -> URL? {
        guard !stopped, let url = shown.first(where: { HomeMapping.id($0, aliases: aliases) == message })?.feedRow?.url else { return nil }
        if url.isCmuxAppLink { return url }
        return ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? url : nil
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
