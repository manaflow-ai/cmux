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

    /// The fields that can change on the sidebar's immediate observation path.
    /// Structured branch, directory, and pull-request details stay in the
    /// existing snapshot until the debounced detail observation refreshes it.
    struct Summary: Equatable {
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let isMuted: Bool
        let customColorHex: String?
        let latestConversationMessage: String?
        let activeCodingAgentCount: Int
        let taskStatus: WorkspaceTaskStatus?
        let todoStatusMenuModel: SidebarWorkspaceCompactStatusMenuModel?
        let hasManualTaskStatus: Bool
        let checklistItems: [WorkspaceChecklistItem]
        let checklistCompletedCount: Int
        let checklistTotalCount: Int
        let checklistFirstUncheckedText: String?
        let taskStatusInput: SidebarWorkspaceTaskStatusSnapshot
    }

    struct Snapshot: Equatable {
        let presentationKey: PresentationKey
        let title: String
        let customDescription: String?
        let isPinned: Bool
        /// Whether any workspace-scoped notification mute is active.
        let isMuted: Bool
        let customColorHex: String?
        /// Stable Cloud identity, independent of connection status and detail visibility.
        let cloudWorkspaceLabel: String?
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
        var taskStatusInput = SidebarWorkspaceTaskStatusSnapshot()
        var deviceWorkspaceLabel: String? = nil

        var remoteWorkspaceBadgeLabel: String? { deviceWorkspaceLabel ?? cloudWorkspaceLabel }
        var remoteWorkspaceBadgeSymbol: String { deviceWorkspaceLabel == nil ? "cloud" : "desktopcomputer" }

        func accessibilityLabel(index: Int, workspaceCount: Int) -> String {
            let position = String(
                localized: "accessibility.workspacePosition",
                defaultValue: "\(title), workspace \(index + 1) of \(workspaceCount)"
            )
            let cloudDirectory = cloudWorkspaceLabel == nil ? nil
                : (compactDirectoryCandidates.first ?? branchDirectoryLines.first?.directory)
            return [position, remoteWorkspaceBadgeLabel, cloudDirectory].compactMap { $0 }.joined(separator: ", ")
        }

        func applying(summary: Summary) -> Self {
            Self(
                presentationKey: presentationKey,
                title: summary.title,
                customDescription: summary.customDescription,
                isPinned: summary.isPinned,
                isMuted: summary.isMuted,
                customColorHex: summary.customColorHex,
                cloudWorkspaceLabel: cloudWorkspaceLabel,
                remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
                remoteConnectionStatusText: remoteConnectionStatusText,
                remoteStateHelpText: remoteStateHelpText,
                showsRemoteReconnectAffordance: showsRemoteReconnectAffordance,
                copyableSidebarSSHError: copyableSidebarSSHError,
                latestConversationMessage: summary.latestConversationMessage,
                metadataEntries: metadataEntries,
                metadataBlocks: metadataBlocks,
                latestLog: latestLog,
                progress: progress,
                activeCodingAgentCount: summary.activeCodingAgentCount,
                compactGitBranchSummaryText: compactGitBranchSummaryText,
                compactDirectoryCandidates: compactDirectoryCandidates,
                compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
                branchDirectoryLines: branchDirectoryLines,
                branchLinesContainBranch: branchLinesContainBranch,
                pullRequestRows: pullRequestRows,
                listeningPorts: listeningPorts,
                finderDirectoryPath: finderDirectoryPath,
                mediaActivity: mediaActivity,
                taskStatus: summary.taskStatus,
                todoStatusMenuModel: summary.todoStatusMenuModel,
                hasManualTaskStatus: summary.hasManualTaskStatus,
                checklistItems: summary.checklistItems,
                checklistCompletedCount: summary.checklistCompletedCount,
                checklistTotalCount: summary.checklistTotalCount,
                checklistFirstUncheckedText: summary.checklistFirstUncheckedText,
                taskStatusInput: summary.taskStatusInput,
                deviceWorkspaceLabel: deviceWorkspaceLabel
            )
        }
    }
}
