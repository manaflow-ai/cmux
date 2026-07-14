import CmuxSidebar
import Foundation

/// Immutable semantic workspace state projected from existing host-side stores.
struct MobileWorkspaceRemoteStateSnapshot: Sendable {
    static let version = 1

    let agents: [MobileWorkspaceAgentStatusSnapshot]
    let git: SidebarGitBranchState?
    let pullRequest: SidebarPullRequestState?
    let unreadCount: Int
    let latestNotificationID: UUID?

    @MainActor
    init(workspace: Workspace, notificationStore: TerminalNotificationStore?) {
        // Workstream actionable events converge into the same lifecycle map via
        // FeedCoordinator's attention overlay, so this captures Workstream and
        // direct sidebar lifecycle updates through one authoritative source.
        agents = MobileWorkspaceAgentStatusSnapshot.capture(workspace: workspace)
        git = workspace.sidebarGitBranchesInDisplayOrder().first
        pullRequest = workspace.sidebarPullRequestsInDisplayOrder().first
        unreadCount = notificationStore?.unreadCount(forTabId: workspace.id) ?? 0
        latestNotificationID = notificationStore?.latestNotification(forTabId: workspace.id)?.id
    }

    var payload: [String: Any] {
        let gitPayload: Any = git.map {
            [
                "branch": $0.branch,
                "is_dirty": $0.isDirty,
            ] as [String: Any]
        } ?? NSNull()
        let pullRequestPayload: Any = pullRequest.map {
            [
                "number": $0.number,
                "state": $0.status.rawValue,
                // The sidebar intentionally stopped polling statusCheckRollup
                // in #2662. Preserve that cheap host behavior and report the
                // honest absence of an authoritative CI result.
                "ci_status": "unknown",
                "url": $0.url.absoluteString,
                "label": $0.label,
                "branch": $0.branch ?? NSNull(),
                "is_stale": $0.isStale,
            ] as [String: Any]
        } ?? NSNull()
        return [
            "version": Self.version,
            "agents": agents.map(\.payload),
            "git": gitPayload,
            "pull_request": pullRequestPayload,
            "notifications": [
                "unread_count": unreadCount,
                "has_unread": unreadCount > 0,
                "latest_notification_id": latestNotificationID?.uuidString ?? NSNull(),
            ],
        ]
    }

    func combineSemanticState(into hasher: inout Hasher) {
        hasher.combine(Self.version)
        hasher.combine(agents.count)
        for agent in agents {
            agent.combine(into: &hasher)
        }
        hasher.combine(git?.branch)
        hasher.combine(git?.isDirty)
        hasher.combine(pullRequest?.number)
        hasher.combine(pullRequest?.status.rawValue)
        hasher.combine(pullRequest?.url.absoluteString)
        hasher.combine(pullRequest?.label)
        hasher.combine(pullRequest?.branch)
        hasher.combine(pullRequest?.isStale)
    }
}
