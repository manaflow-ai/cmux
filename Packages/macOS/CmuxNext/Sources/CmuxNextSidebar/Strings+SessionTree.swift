import Foundation

extension Strings {
    /// A row's pull request badge, for VoiceOver (`sidebar.sessionTree`).
    static func pullRequests(_ badge: SidebarPullRequestBadge) -> String {
        let count = badge.count
        return switch badge.status {
        case .passing:
            String(localized: "sidebar.a11y.pullRequests.passing", defaultValue: "Pull requests: \(count), open", bundle: .module)
        case .attention:
            String(localized: "sidebar.a11y.pullRequests.attention", defaultValue: "Pull requests: \(count), need attention", bundle: .module)
        case .failing:
            String(localized: "sidebar.a11y.pullRequests.failing", defaultValue: "Pull requests: \(count), checks failed", bundle: .module)
        case .merged:
            String(localized: "sidebar.a11y.pullRequests.merged", defaultValue: "Pull requests: \(count), merged", bundle: .module)
        }
    }
}

extension Strings {
    /// The pull requests' hover card, for VoiceOver (`SidebarPullRequestCard`).
    static var pullRequestCardTitle: String {
        String(localized: "sidebar.pullRequestCard.title", defaultValue: "Pull requests", bundle: .module)
    }

    /// A pull request's state pill in the hover card.
    static func pullRequestState(_ state: SidebarPullRequestItem.State) -> String {
        switch state {
        case .conflict: String(localized: "sidebar.pullRequestCard.state.conflict", defaultValue: "Conflict", bundle: .module)
        case .failing: String(localized: "sidebar.pullRequestCard.state.failing", defaultValue: "Checks failed", bundle: .module)
        case .passing: String(localized: "sidebar.pullRequestCard.state.passing", defaultValue: "Checks passing", bundle: .module)
        case .draft: String(localized: "sidebar.pullRequestCard.state.draft", defaultValue: "Draft", bundle: .module)
        case .merged: String(localized: "sidebar.pullRequestCard.state.merged", defaultValue: "Merged", bundle: .module)
        case .closed: String(localized: "sidebar.pullRequestCard.state.closed", defaultValue: "Closed", bundle: .module)
        }
    }

    /// One line of the hover card, for VoiceOver: title, state, `owner/repo #N`, size.
    static func pullRequestCardRow(_ item: SidebarPullRequestItem) -> String {
        let title = item.title, state = pullRequestState(item.state)
        let place = item.repository.isEmpty ? "#\(item.number)" : "\(item.repository) #\(item.number)"
        let added = item.additions, removed = item.deletions
        return String(localized: "sidebar.a11y.pullRequestCard.row",
                      defaultValue: "\(title), \(state), \(place), \(added) lines added, \(removed) lines removed", bundle: .module)
    }
}
