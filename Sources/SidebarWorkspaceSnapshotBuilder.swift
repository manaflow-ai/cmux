import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Workspace sidebar snapshot value types extracted from `ContentView.swift`, which sits at its file-length budget.
struct SidebarWorkspaceSnapshotBuilder {
    struct PresentationKey: Equatable {
        let showsWorkspaceDescription: Bool
        let usesVerticalBranchLayout: Bool
        let showsGitBranch: Bool
        let usesViewportAwarePath: Bool
        let showsAgentActivity: Bool
        let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
        // Effective row color (manual color, else resolved origin color). Part of
        // the key so the cached snapshot is rebuilt when the color changes — e.g.
        // toggling the origin-colors flag or a mirror host resolving after appear,
        // neither of which is a Workspace @Published change that would otherwise
        // refresh the snapshot.
        let customColorHex: String?
    }

    struct VerticalBranchDirectoryLine: Equatable {
        let branch: String?
        // Ordered longest → shortest. Empty means no directory to show.
        // First element is the canonical display string when only one is needed.
        let directoryCandidates: [String]

        var directory: String? { directoryCandidates.first }
    }

    struct PullRequestDisplay: Identifiable, Equatable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let isStale: Bool
    }

    struct Snapshot: Equatable {
        let presentationKey: PresentationKey
        let title: String
        let customDescription: String?
        let isPinned: Bool
        // Effective row color: the manually chosen workspace color, else the
        // per-host origin color when that beta flag is on. Rendering reads this;
        // affordances that only make sense for a manual color (Clear Color)
        // check `hasManualCustomColor` instead.
        let customColorHex: String?
        let hasManualCustomColor: Bool
        let remoteWorkspaceSidebarText: String?
        let remoteConnectionStatusText: String
        let remoteStateHelpText: String
        let showsRemoteReconnectAffordance: Bool
        let copyableSidebarSSHError: String?
        let latestConversationMessage: String?
        let metadataEntries: [SidebarStatusEntry]
        let metadataBlocks: [SidebarMetadataBlock]
        let latestLog: SidebarLogEntry?
        let progress: SidebarProgressState?
        let activeCodingAgentCount: Int
        let compactGitBranchSummaryText: String?
        let compactDirectoryCandidates: [String]
        let compactBranchDirectoryCandidates: [String]
        let branchDirectoryLines: [VerticalBranchDirectoryLine]
        let branchLinesContainBranch: Bool
        let pullRequestRows: [PullRequestDisplay]
        let listeningPorts: [Int]
        let finderDirectoryPath: String?
        let mediaActivity: BrowserMediaActivity
        // Workspace todo status/checklist; taskStatus is nil when the
        // workspace opted out of status display or the remote todo-controls
        // flag is off. Manual status draws a compact row indicator, while
        // automatic status still only drives the done-row dim.
        let taskStatus: WorkspaceTaskStatus?
        let todoStatusMenuModel: SidebarWorkspaceCompactStatusMenuModel?
        let hasManualTaskStatus: Bool
        let checklistItems: [WorkspaceChecklistItem]
        let checklistCompletedCount: Int
        let checklistTotalCount: Int
        let checklistFirstUncheckedText: String?
    }
}
