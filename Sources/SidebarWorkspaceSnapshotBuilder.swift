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
        var compactsAgentStatus = false
        var compactStatusIcons: [String: String] = [:]
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
        /// The single leading status glyph when `sidebar.compactAgentStatus`
        /// is on (agent status entries then leave `metadataEntries`).
        var compactStatusGlyph: SidebarCompactStatusGlyph? = nil

        /// Human-readable provenance for the small leading workspace badge.
        ///
        /// Cloud and device workspaces already have a stable machine label. A
        /// plain SSH workspace used to leave this slot empty, which made an
        /// SSH row look like a local workspace until the reader noticed the
        /// second-line target. Keep the target in the same identity slot so
        /// remote workspaces are distinguishable at a glance.
        var remoteWorkspaceBadgeLabel: String? {
            if let deviceWorkspaceLabel { return deviceWorkspaceLabel }
            if let cloudWorkspaceLabel { return cloudWorkspaceLabel }
            guard let target = remoteWorkspaceSidebarText else { return nil }
            return String.localizedStringWithFormat(
                String(localized: "sidebar.sshWorkspace.label", defaultValue: "SSH workspace on %@"),
                target
            )
        }

        var remoteWorkspaceBadgeSymbol: String {
            if deviceWorkspaceLabel != nil { return "desktopcomputer" }
            if cloudWorkspaceLabel != nil { return "cloud" }
            return remoteWorkspaceSidebarText == nil ? "cloud" : "network"
        }

        func accessibilityLabel(index: Int, workspaceCount: Int) -> String {
            let position = String(
                localized: "accessibility.workspacePosition",
                defaultValue: "\(title), workspace \(index + 1) of \(workspaceCount)"
            )
            let cloudDirectory = cloudWorkspaceLabel == nil ? nil
                : (compactDirectoryCandidates.first ?? branchDirectoryLines.first?.directory)
            return [position, remoteWorkspaceBadgeLabel, cloudDirectory].compactMap { $0 }.joined(separator: ", ")
        }
    }
}
