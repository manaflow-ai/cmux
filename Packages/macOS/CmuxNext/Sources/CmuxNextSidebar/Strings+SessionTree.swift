import Foundation

extension Strings {
    /// A row's pull request badge, for VoiceOver (`sidebar.sessionTree`).
    static func pullRequests(_ badge: SidebarPullRequestBadge) -> String {
        let count = badge.count
        return switch badge.status {
        case .passing:
            String(localized: "sidebar.a11y.pullRequests.passing", defaultValue: "Pull requests: \(count), open", bundle: .l10n)
        case .attention:
            String(localized: "sidebar.a11y.pullRequests.attention", defaultValue: "Pull requests: \(count), need attention", bundle: .l10n)
        case .failing:
            String(localized: "sidebar.a11y.pullRequests.failing", defaultValue: "Pull requests: \(count), checks failed", bundle: .l10n)
        case .merged:
            String(localized: "sidebar.a11y.pullRequests.merged", defaultValue: "Pull requests: \(count), merged", bundle: .l10n)
        }
    }

    /// A started session's row title when it would repeat its parent's name.
    static func subagentOf(_ parent: String) -> String {
        String(localized: "sidebar.sessionTree.subagentOf", defaultValue: "Subagent of \(parent)", bundle: .l10n)
    }

    /// A tree parent's chevron and VoiceOver action: fold the sessions it started out of sight.
    static var collapseSessions: String {
        String(localized: "sidebar.sessionTree.collapse", defaultValue: "Hide Started Sessions", bundle: .l10n)
    }

    /// A folded tree parent's chevron and VoiceOver action: show the sessions it started.
    static var expandSessions: String {
        String(localized: "sidebar.sessionTree.expand", defaultValue: "Show Started Sessions", bundle: .l10n)
    }

    /// A folded parent's roll-up chips, for VoiceOver: what its hidden sessions are doing.
    static func rollUp(_ rollUp: SidebarTreeRollUp) -> String {
        var parts: [String] = []
        if rollUp.blocked > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.blocked", defaultValue: "\(rollUp.blocked) waiting on you", bundle: .l10n))
        }
        if rollUp.failed > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.failed", defaultValue: "\(rollUp.failed) failed", bundle: .l10n))
        }
        if rollUp.running > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.running", defaultValue: "\(rollUp.running) running", bundle: .l10n))
        }
        if rollUp.unread > 0 {
            parts.append(String(localized: "sidebar.a11y.rollUp.unread", defaultValue: "\(rollUp.unread) finished, unread", bundle: .l10n))
        }
        return String(localized: "sidebar.a11y.rollUp", defaultValue: "Started sessions: \(parts.joined(separator: ", "))", bundle: .l10n)
    }
}

extension Strings {
    /// The pull requests' hover card, for VoiceOver (`SidebarPullRequestCard`).
    static var pullRequestCardTitle: String {
        String(localized: "sidebar.pullRequestCard.title", defaultValue: "Pull requests", bundle: .l10n)
    }

    /// A pull request's state pill in the hover card.
    static func pullRequestState(_ state: SidebarPullRequestItem.State) -> String {
        switch state {
        case .conflict: String(localized: "sidebar.pullRequestCard.state.conflict", defaultValue: "Conflict", bundle: .l10n)
        case .failing: String(localized: "sidebar.pullRequestCard.state.failing", defaultValue: "Checks failed", bundle: .l10n)
        case .passing: String(localized: "sidebar.pullRequestCard.state.passing", defaultValue: "Checks passing", bundle: .l10n)
        case .draft: String(localized: "sidebar.pullRequestCard.state.draft", defaultValue: "Draft", bundle: .l10n)
        case .merged: String(localized: "sidebar.pullRequestCard.state.merged", defaultValue: "Merged", bundle: .l10n)
        case .closed: String(localized: "sidebar.pullRequestCard.state.closed", defaultValue: "Closed", bundle: .l10n)
        }
    }

    /// One line of the hover card, for VoiceOver: title, state, `owner/repo #N`, size.
    static func pullRequestCardRow(_ item: SidebarPullRequestItem) -> String {
        let title = item.title, state = pullRequestState(item.state)
        let place = item.repository.isEmpty ? "#\(item.number)" : "\(item.repository) #\(item.number)"
        let added = item.additions, removed = item.deletions
        return String(localized: "sidebar.a11y.pullRequestCard.row",
                      defaultValue: "\(title), \(state), \(place), \(added) lines added, \(removed) lines removed", bundle: .l10n)
    }
}
