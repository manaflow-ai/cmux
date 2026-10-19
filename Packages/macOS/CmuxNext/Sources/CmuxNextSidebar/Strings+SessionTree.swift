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
