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
}
