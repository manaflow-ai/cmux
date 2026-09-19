import CmuxGit
import CmuxSidebar

extension SidebarPullRequestChecks {
    init(_ summary: PullRequestChecksSummary) {
        self.init(
            status: SidebarPullRequestCheckStatus(rawValue: summary.status.rawValue) ?? .unavailable,
            checks: summary.checks.map {
                SidebarPullRequestCheck(
                    id: $0.id, name: $0.name,
                    status: SidebarPullRequestCheckStatus(rawValue: $0.status.rawValue) ?? .unavailable,
                    detailsURL: $0.detailsURL
                )
            },
            mergeStatus: SidebarPullRequestMergeStatus(rawValue: summary.mergeStatus.rawValue) ?? .unknown
        )
    }

    var gitSummary: PullRequestChecksSummary {
        PullRequestChecksSummary(
            status: PullRequestCheckStatus(rawValue: status.rawValue) ?? .unavailable,
            checks: checks.map {
                PullRequestCheck(
                    id: $0.id, name: $0.name,
                    status: PullRequestCheckStatus(rawValue: $0.status.rawValue) ?? .unavailable,
                    detailsURL: $0.detailsURL
                )
            },
            mergeStatus: PullRequestMergeStatus(rawValue: mergeStatus.rawValue) ?? .unknown
        )
    }
}
