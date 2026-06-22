public import CmuxSidebar
public import CoreGraphics
public import SwiftUI

/// The auxiliary-detail cluster shown under a workspace row's title and remote
/// section: metadata pills and markdown blocks, the latest log entry, an agent
/// progress bar, the git branch + directory line, pull-request badges, and
/// listening ports.
///
/// Each cluster is gated by ``SidebarWorkspaceAuxiliaryDetailVisibility`` and
/// composes the already-extracted per-detail row views. Every input is a
/// precomputed value snapshot (the resolved
/// ``SidebarWorkspaceSnapshotBuilder/Snapshot`` plus colors derived by the
/// host) or an action/label closure, so the view holds no `@Observable` store
/// reference and stays compliant with the LazyVStack snapshot-boundary rule.
public struct SidebarWorkspaceDetailsStack: View {
    let snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    let detailVisibility: SidebarWorkspaceAuxiliaryDetailVisibility
    let isActive: Bool
    let activeSecondaryColor: (Double) -> Color
    let progressTrackColor: Color
    let progressFillColor: Color
    let branchSecondaryColor: Color
    let branchIconColor: Color
    let usesVerticalBranchLayout: Bool
    let stacksBranchAndDirectory: Bool
    let showsGitBranchIcon: Bool
    let pullRequestForegroundColor: Color
    let makesPullRequestsClickable: Bool
    let fontScale: CGFloat
    let onFocus: () -> Void
    let pullRequestStatusLabel: (SidebarPullRequestStatus) -> String
    let pullRequestOpenTooltip: (String) -> String
    let onOpenPullRequest: (URL) -> Void
    let portLabel: (Int) -> String
    let portTooltip: (Int) -> String
    let onOpenPort: (Int) -> Void

    /// Creates the auxiliary-detail cluster.
    /// - Parameters:
    ///   - snapshot: The fully-resolved sidebar row snapshot.
    ///   - detailVisibility: Which auxiliary detail clusters are shown.
    ///   - isActive: Whether the row is the active workspace (inverts foreground).
    ///   - activeSecondaryColor: Maps an opacity to the active/secondary color.
    ///   - progressTrackColor: Track color for the progress bar.
    ///   - progressFillColor: Fill color for the progress bar.
    ///   - branchSecondaryColor: Foreground color for branch/directory text.
    ///   - branchIconColor: Foreground color for the branch glyph and separator.
    ///   - usesVerticalBranchLayout: Selects the multi-line vertical branch layout.
    ///   - stacksBranchAndDirectory: Stacks branch over directory in compact mode.
    ///   - showsGitBranchIcon: Whether to show the branch glyph.
    ///   - pullRequestForegroundColor: Foreground color for pull-request badges.
    ///   - makesPullRequestsClickable: Whether pull-request badges open links.
    ///   - fontScale: Multiplier applied to base font sizes.
    ///   - onFocus: Called when a metadata row is focused.
    ///   - pullRequestStatusLabel: Localized label for a pull-request status.
    ///   - pullRequestOpenTooltip: Localized open tooltip for a pull-request title.
    ///   - onOpenPullRequest: Called to open a pull-request URL.
    ///   - portLabel: Localized label for a listening port.
    ///   - portTooltip: Localized open tooltip for a listening port.
    ///   - onOpenPort: Called to open a listening port.
    public init(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        detailVisibility: SidebarWorkspaceAuxiliaryDetailVisibility,
        isActive: Bool,
        activeSecondaryColor: @escaping (Double) -> Color,
        progressTrackColor: Color,
        progressFillColor: Color,
        branchSecondaryColor: Color,
        branchIconColor: Color,
        usesVerticalBranchLayout: Bool,
        stacksBranchAndDirectory: Bool,
        showsGitBranchIcon: Bool,
        pullRequestForegroundColor: Color,
        makesPullRequestsClickable: Bool,
        fontScale: CGFloat,
        onFocus: @escaping () -> Void,
        pullRequestStatusLabel: @escaping (SidebarPullRequestStatus) -> String,
        pullRequestOpenTooltip: @escaping (String) -> String,
        onOpenPullRequest: @escaping (URL) -> Void,
        portLabel: @escaping (Int) -> String,
        portTooltip: @escaping (Int) -> String,
        onOpenPort: @escaping (Int) -> Void
    ) {
        self.snapshot = snapshot
        self.detailVisibility = detailVisibility
        self.isActive = isActive
        self.activeSecondaryColor = activeSecondaryColor
        self.progressTrackColor = progressTrackColor
        self.progressFillColor = progressFillColor
        self.branchSecondaryColor = branchSecondaryColor
        self.branchIconColor = branchIconColor
        self.usesVerticalBranchLayout = usesVerticalBranchLayout
        self.stacksBranchAndDirectory = stacksBranchAndDirectory
        self.showsGitBranchIcon = showsGitBranchIcon
        self.pullRequestForegroundColor = pullRequestForegroundColor
        self.makesPullRequestsClickable = makesPullRequestsClickable
        self.fontScale = fontScale
        self.onFocus = onFocus
        self.pullRequestStatusLabel = pullRequestStatusLabel
        self.pullRequestOpenTooltip = pullRequestOpenTooltip
        self.onOpenPullRequest = onOpenPullRequest
        self.portLabel = portLabel
        self.portTooltip = portTooltip
        self.onOpenPort = onOpenPort
    }

    @ViewBuilder
    public var body: some View {
        if detailVisibility.showsMetadata {
            let metadataEntries = snapshot.metadataEntries
            let metadataBlocks = snapshot.metadataBlocks
            if !metadataEntries.isEmpty {
                SidebarMetadataRows(
                    entries: metadataEntries,
                    isActive: isActive,
                    activeForegroundColor: activeSecondaryColor(0.95),
                    activeSecondaryForegroundColor: activeSecondaryColor(0.65),
                    fontScale: fontScale,
                    onFocus: onFocus
                )
                .transition(.opacity)
            }
            if !metadataBlocks.isEmpty {
                SidebarMetadataMarkdownBlocks(
                    blocks: metadataBlocks,
                    isActive: isActive,
                    activeForegroundColor: activeSecondaryColor(0.8),
                    activeSecondaryForegroundColor: activeSecondaryColor(0.65),
                    fontScale: fontScale,
                    onFocus: onFocus
                )
                .transition(.opacity)
            }
        }

        if detailVisibility.showsLog, let latestLog = snapshot.latestLog {
            SidebarWorkspaceLogRow(
                entry: latestLog,
                isActive: isActive,
                activeSecondaryColor: activeSecondaryColor,
                messageColor: activeSecondaryColor(0.8),
                fontScale: fontScale
            )
            .transition(.opacity)
        }

        if detailVisibility.showsProgress, let progress = snapshot.progress {
            SidebarWorkspaceProgressRow(
                value: progress.value,
                label: progress.label,
                trackColor: progressTrackColor,
                fillColor: progressFillColor,
                labelColor: activeSecondaryColor(0.6),
                fontScale: fontScale
            )
            .transition(.opacity)
        }

        // Branch + directory row
        if detailVisibility.showsBranchDirectory {
            SidebarWorkspaceBranchDirectoryRow(
                branchDirectoryLines: snapshot.branchDirectoryLines,
                branchLinesContainBranch: snapshot.branchLinesContainBranch,
                compactGitBranchSummaryText: snapshot.compactGitBranchSummaryText,
                compactDirectoryCandidates: snapshot.compactDirectoryCandidates,
                compactBranchDirectoryCandidates: snapshot.compactBranchDirectoryCandidates,
                usesVerticalBranchLayout: usesVerticalBranchLayout,
                stacksBranchAndDirectory: stacksBranchAndDirectory,
                showsGitBranchIcon: showsGitBranchIcon,
                secondaryColor: branchSecondaryColor,
                iconColor: branchIconColor,
                fontScale: fontScale
            )
        }

        // Pull request rows
        if detailVisibility.showsPullRequests, !snapshot.pullRequestRows.isEmpty {
            SidebarWorkspacePullRequestRows(
                pullRequests: snapshot.pullRequestRows,
                foregroundColor: pullRequestForegroundColor,
                fontScale: fontScale,
                makesClickable: makesPullRequestsClickable,
                statusLabel: pullRequestStatusLabel,
                openTooltip: pullRequestOpenTooltip,
                onOpen: onOpenPullRequest
            )
        }

        // Ports row
        if detailVisibility.showsPorts, !snapshot.listeningPorts.isEmpty {
            SidebarWorkspacePortsRow(
                ports: snapshot.listeningPorts,
                color: activeSecondaryColor(0.75),
                fontScale: fontScale,
                portLabel: portLabel,
                portTooltip: portTooltip,
                onOpen: onOpenPort
            )
        }
    }
}
