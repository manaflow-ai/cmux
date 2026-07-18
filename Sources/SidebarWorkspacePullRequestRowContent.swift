import CmuxSidebar
import Foundation

/// Immutable pull-request presentation shared by both sidebar renderers.
struct SidebarWorkspacePullRequestRowContent: Equatable, Identifiable {
    let id: String
    let title: String
    let url: URL
    let status: SidebarPullRequestStatus
    let statusLabel: String
    let openTooltip: String
    let isStale: Bool
    let isClickable: Bool

    init(
        display: SidebarWorkspaceSnapshotBuilder.PullRequestDisplay,
        isClickable: Bool
    ) {
        id = display.id
        let resolvedTitle = "\(display.label) #\(display.number)"
        title = resolvedTitle
        url = display.url
        status = display.status
        statusLabel = switch display.status {
        case .open:
            String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged:
            String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed:
            String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
        openTooltip = String(
            localized: "sidebar.pullRequest.openTooltip",
            defaultValue: "Open \(display.label) #\(display.number)"
        )
        isStale = display.isStale
        self.isClickable = isClickable
    }
}
