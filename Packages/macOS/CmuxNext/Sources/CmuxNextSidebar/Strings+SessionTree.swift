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

    /// A tree parent's chevron and VoiceOver action: fold the sessions it started out of sight.
    static var collapseSessions: String {
        String(localized: "sidebar.sessionTree.collapse", defaultValue: "Hide Started Sessions", bundle: .module)
    }

    /// A folded tree parent's chevron and VoiceOver action: show the sessions it started.
    static var expandSessions: String {
        String(localized: "sidebar.sessionTree.expand", defaultValue: "Show Started Sessions", bundle: .module)
    }

    /// A folded parent's roll-up chips, for VoiceOver: what its hidden sessions are doing.
    static func rollUp(_ rollUp: SidebarTreeRollUp) -> String {
        var parts: [String] = []
        if rollUp.total > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.total", defaultValue: "\(rollUp.total) sessions", bundle: .module))
        }
        if rollUp.blocked > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.blocked", defaultValue: "\(rollUp.blocked) waiting on you", bundle: .module))
        }
        if rollUp.failed > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.failed", defaultValue: "\(rollUp.failed) failed", bundle: .module))
        }
        if rollUp.running > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.running", defaultValue: "\(rollUp.running) running", bundle: .module))
        }
        if rollUp.unread > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.unread", defaultValue: "\(rollUp.unread) finished, unread", bundle: .module))
        }
        return String(localized: "sidebar.a11y.rollUp", defaultValue: "Started sessions: \(parts.joined(separator: ", "))", bundle: .module)
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
