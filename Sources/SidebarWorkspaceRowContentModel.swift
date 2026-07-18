import CmuxFoundation
import Foundation

/// Shared immutable presentation model for SwiftUI and AppKit workspace rows.
///
/// The parent sidebar projection creates this value once from the authoritative
/// workspace snapshot and settings. Renderers only choose native controls and
/// geometry; they do not independently decide which content is visible.
struct SidebarWorkspaceRowContentModel: Equatable {
    let title: String
    let titleLineLimit: Int
    let subtitle: String?
    let subtitleLineLimit: Int
    let statusRows: [SidebarWorkspaceStatusRowContent]
    let branchDirectoryRows: [SidebarWorkspaceBranchDirectoryRowContent]
    let showsBranchIcon: Bool
    let pullRequestRows: [SidebarWorkspacePullRequestRowContent]

    private let alwaysShowsShortcutHints: Bool

    init(
        workspace: SidebarWorkspaceSnapshotBuilder.Snapshot,
        settings: SidebarTabItemSettingsSnapshot,
        latestNotificationText: String?
    ) {
        titleLineLimit = settings.wrapsWorkspaceTitles ? 8 : 1
        title = workspace.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: 2048
        )

        let notificationSubtitle = settings.showsNotificationMessage
            ? latestNotificationText
            : nil
        let conversationSubtitle: String? = {
            guard !settings.hidesAllDetails, settings.iMessageModeEnabled else { return nil }
            return workspace.latestConversationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }()
        let effectiveSubtitle = notificationSubtitle ?? conversationSubtitle
        subtitleLineLimit = notificationSubtitle == nil ? 2 : settings.notificationMessageLineLimit
        subtitle = effectiveSubtitle?.sidebarBoundedDisplayString(
            maxDisplayedLines: subtitleLineLimit,
            maxDisplayedCharacters: 4096
        )

        statusRows = settings.visibleAuxiliaryDetails.showsMetadata
            ? workspace.metadataEntries.map(SidebarWorkspaceStatusRowContent.init)
            : []

        branchDirectoryRows = Self.branchDirectoryRows(
            workspace: workspace,
            settings: settings
        )
        showsBranchIcon = settings.visibleAuxiliaryDetails.showsBranchDirectory
            && settings.showsGitBranchIcon
            && !branchDirectoryRows.isEmpty
            && (settings.usesVerticalBranchLayout
                ? branchDirectoryRows.contains { $0.branch != nil }
                : workspace.compactGitBranchSummaryText != nil)

        pullRequestRows = settings.visibleAuxiliaryDetails.showsPullRequests
            ? workspace.pullRequestRows.map {
                SidebarWorkspacePullRequestRowContent(
                    display: $0,
                    isClickable: settings.makesPullRequestsClickable
                )
            }
            : []
        alwaysShowsShortcutHints = settings.alwaysShowShortcutHints
    }

    func showsCloseButton(
        isPointerHovering: Bool,
        contextMenuVisible: Bool,
        canCloseWorkspace: Bool,
        showsModifierShortcutHints: Bool
    ) -> Bool {
        isPointerHovering
            && !contextMenuVisible
            && canCloseWorkspace
            && !(showsModifierShortcutHints || alwaysShowsShortcutHints)
    }

    private static func branchDirectoryRows(
        workspace: SidebarWorkspaceSnapshotBuilder.Snapshot,
        settings: SidebarTabItemSettingsSnapshot
    ) -> [SidebarWorkspaceBranchDirectoryRowContent] {
        guard settings.visibleAuxiliaryDetails.showsBranchDirectory else { return [] }

        if settings.usesVerticalBranchLayout {
            return workspace.branchDirectoryLines.map {
                SidebarWorkspaceBranchDirectoryRowContent(
                    branch: settings.showsGitBranch ? $0.branch : nil,
                    directoryCandidates: $0.directoryCandidates,
                    stacksBranchAndDirectory: settings.stacksBranchAndDirectory
                )
            }
        }

        if settings.stacksBranchAndDirectory {
            guard workspace.compactGitBranchSummaryText != nil
                    || !workspace.compactDirectoryCandidates.isEmpty else {
                return []
            }
            return [
                SidebarWorkspaceBranchDirectoryRowContent(
                    branch: workspace.compactGitBranchSummaryText,
                    directoryCandidates: workspace.compactDirectoryCandidates,
                    stacksBranchAndDirectory: true
                ),
            ]
        }

        guard !workspace.compactBranchDirectoryCandidates.isEmpty else { return [] }
        return [
            SidebarWorkspaceBranchDirectoryRowContent(
                branch: nil,
                directoryCandidates: workspace.compactBranchDirectoryCandidates,
                stacksBranchAndDirectory: false
            ),
        ]
    }
}
