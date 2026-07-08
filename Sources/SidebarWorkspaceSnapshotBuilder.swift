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
        let customColorHex: String?
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
        // Workspace todo status/checklist; taskStatus is nil while the
        // workspace-todos beta is disabled (no glyph slot reserved).
        let taskStatus: WorkspaceTaskStatus?
        let taskStatusHasOverride: Bool
        /// The lane the live signals currently infer; feeds the status
        /// popover's Auto row.
        let taskStatusInferred: WorkspaceTaskStatus?
        let checklistItems: [WorkspaceChecklistItem]
        let checklistCompletedCount: Int
        let checklistTotalCount: Int
        let checklistFirstUncheckedText: String?
    }
}
