public import CmuxSidebar
public import CmuxSettings
public import CoreGraphics
public import SwiftUI

/// The inner content column of a workspace sidebar row: the header (title,
/// unread/memory badges, pin, close), the optional custom description, the
/// optional subtitle, the optional remote-connection section, and the
/// auxiliary-detail cluster (``SidebarWorkspaceDetailsStack``).
///
/// This is the `VStack(alignment: .leading, spacing: 4)` that `TabItemView`
/// previously inlined. Every input is a precomputed value snapshot (the
/// resolved ``SidebarWorkspaceSnapshotBuilder/Snapshot`` plus colors, strings,
/// and visibility flags derived by the host) or an action/label closure, so the
/// view holds no `@Observable` store reference and stays compliant with the
/// LazyVStack snapshot-boundary rule. The row chrome (background, drop
/// indicators, gestures, context menu) stays on the host. When the workspace
/// title is being edited, the host injects the inline editor view so app-target
/// rename policy and AppKit field coordination do not move into the package.
public struct SidebarWorkspaceRowContent<EditingTitleContent: View>: View {
    let snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    let detailVisibility: SidebarWorkspaceAuxiliaryDetailVisibility
    let isActive: Bool

    // Header
    let unreadCount: Int
    let unreadBadgeFillColor: Color
    let unreadBadgeTextColor: Color
    let unreadBadgeDiameter: CGFloat
    let unreadBadgePosition: SidebarIndicatorPosition
    let showsLoadingSpinner: Bool
    let loadingSpinnerPosition: SidebarIndicatorPosition
    let loadingSpinnerColor: Color
    let loadingSpinnerTooltip: String
    let hasMemoryWarning: Bool
    let memoryWarningTooltip: String
    let memoryWarningAccessibilityLabel: String
    let pinnedTooltip: String
    let displayedTitle: String
    let titleColor: Color
    let titleFontWeight: Font.Weight
    let titleLineLimit: Int
    let isTitleEditing: Bool
    let editingTitleContent: EditingTitleContent
    let pinIconColor: Color
    let closeButtonColor: Color
    let showsCloseButton: Bool
    let closeButtonVisible: Bool
    let closeButtonWidth: CGFloat
    let closeButtonHitSize: CGFloat
    let closeButtonTooltip: String
    let onClose: () -> Void

    // Description + subtitle
    let descriptionActiveForegroundColor: Color
    let descriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)?
    let subtitle: String?
    let subtitleColor: Color

    // Remote section
    let showsRemoteSection: Bool
    let remoteHostColor: Color
    let remoteStatusColor: Color
    let remoteReconnectColor: Color
    let remoteTopPadding: CGFloat
    let onReconnect: () -> Void

    // Details stack colors / flags
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

    /// Creates the inner content column for a workspace sidebar row.
    public init(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        detailVisibility: SidebarWorkspaceAuxiliaryDetailVisibility,
        isActive: Bool,
        unreadCount: Int,
        unreadBadgeFillColor: Color,
        unreadBadgeTextColor: Color,
        unreadBadgeDiameter: CGFloat,
        unreadBadgePosition: SidebarIndicatorPosition,
        showsLoadingSpinner: Bool,
        loadingSpinnerPosition: SidebarIndicatorPosition,
        loadingSpinnerColor: Color,
        loadingSpinnerTooltip: String,
        hasMemoryWarning: Bool,
        memoryWarningTooltip: String,
        memoryWarningAccessibilityLabel: String,
        pinnedTooltip: String,
        displayedTitle: String,
        titleColor: Color,
        titleFontWeight: Font.Weight,
        titleLineLimit: Int,
        isTitleEditing: Bool,
        pinIconColor: Color,
        closeButtonColor: Color,
        showsCloseButton: Bool,
        closeButtonVisible: Bool,
        closeButtonWidth: CGFloat,
        closeButtonHitSize: CGFloat,
        closeButtonTooltip: String,
        onClose: @escaping () -> Void,
        descriptionActiveForegroundColor: Color,
        descriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)?,
        subtitle: String?,
        subtitleColor: Color,
        showsRemoteSection: Bool,
        remoteHostColor: Color,
        remoteStatusColor: Color,
        remoteReconnectColor: Color,
        remoteTopPadding: CGFloat,
        onReconnect: @escaping () -> Void,
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
        onOpenPort: @escaping (Int) -> Void,
        @ViewBuilder editingTitleContent: () -> EditingTitleContent
    ) {
        self.snapshot = snapshot
        self.detailVisibility = detailVisibility
        self.isActive = isActive
        self.unreadCount = unreadCount
        self.unreadBadgeFillColor = unreadBadgeFillColor
        self.unreadBadgeTextColor = unreadBadgeTextColor
        self.unreadBadgeDiameter = unreadBadgeDiameter
        self.unreadBadgePosition = unreadBadgePosition
        self.showsLoadingSpinner = showsLoadingSpinner
        self.loadingSpinnerPosition = loadingSpinnerPosition
        self.loadingSpinnerColor = loadingSpinnerColor
        self.loadingSpinnerTooltip = loadingSpinnerTooltip
        self.hasMemoryWarning = hasMemoryWarning
        self.memoryWarningTooltip = memoryWarningTooltip
        self.memoryWarningAccessibilityLabel = memoryWarningAccessibilityLabel
        self.pinnedTooltip = pinnedTooltip
        self.displayedTitle = displayedTitle
        self.titleColor = titleColor
        self.titleFontWeight = titleFontWeight
        self.titleLineLimit = titleLineLimit
        self.isTitleEditing = isTitleEditing
        self.editingTitleContent = editingTitleContent()
        self.pinIconColor = pinIconColor
        self.closeButtonColor = closeButtonColor
        self.showsCloseButton = showsCloseButton
        self.closeButtonVisible = closeButtonVisible
        self.closeButtonWidth = closeButtonWidth
        self.closeButtonHitSize = closeButtonHitSize
        self.closeButtonTooltip = closeButtonTooltip
        self.onClose = onClose
        self.descriptionActiveForegroundColor = descriptionActiveForegroundColor
        self.descriptionDebugLog = descriptionDebugLog
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.showsRemoteSection = showsRemoteSection
        self.remoteHostColor = remoteHostColor
        self.remoteStatusColor = remoteStatusColor
        self.remoteReconnectColor = remoteReconnectColor
        self.remoteTopPadding = remoteTopPadding
        self.onReconnect = onReconnect
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarWorkspaceHeaderRow(
                unreadCount: unreadCount,
                unreadBadgeFillColor: unreadBadgeFillColor,
                unreadBadgeTextColor: unreadBadgeTextColor,
                unreadBadgeDiameter: unreadBadgeDiameter,
                unreadBadgePosition: unreadBadgePosition,
                showsLoadingSpinner: showsLoadingSpinner,
                loadingSpinnerPosition: loadingSpinnerPosition,
                loadingSpinnerColor: loadingSpinnerColor,
                loadingSpinnerTooltip: loadingSpinnerTooltip,
                hasMemoryWarning: hasMemoryWarning,
                memoryWarningTooltip: memoryWarningTooltip,
                memoryWarningAccessibilityLabel: memoryWarningAccessibilityLabel,
                isPinned: snapshot.isPinned,
                pinnedTooltip: pinnedTooltip,
                title: displayedTitle,
                titleColor: titleColor,
                titleFontWeight: titleFontWeight,
                titleLineLimit: titleLineLimit,
                isTitleEditing: isTitleEditing,
                pinIconColor: pinIconColor,
                closeButtonColor: closeButtonColor,
                fontScale: fontScale,
                showsCloseButton: showsCloseButton,
                closeButtonVisible: closeButtonVisible,
                closeButtonWidth: closeButtonWidth,
                closeButtonHitSize: closeButtonHitSize,
                closeButtonTooltip: closeButtonTooltip,
                onClose: onClose,
                editingTitleContent: { editingTitleContent }
            )

            if let description = snapshot.customDescription {
                SidebarWorkspaceDescriptionText(
                    markdown: description,
                    isActive: isActive,
                    activeForegroundColor: descriptionActiveForegroundColor,
                    fontScale: fontScale,
                    debugLog: descriptionDebugLog
                )
            }

            if let subtitle {
                SidebarWorkspaceSubtitleText(
                    text: subtitle,
                    color: subtitleColor,
                    fontScale: fontScale
                )
            }

            if showsRemoteSection, let remoteWorkspaceSidebarText = snapshot.remoteWorkspaceSidebarText {
                SidebarWorkspaceRemoteRow(
                    hostText: remoteWorkspaceSidebarText,
                    connectionStatusText: snapshot.remoteConnectionStatusText,
                    showsReconnectAffordance: snapshot.showsRemoteReconnectAffordance,
                    stateHelpText: snapshot.remoteStateHelpText,
                    hostColor: remoteHostColor,
                    statusColor: remoteStatusColor,
                    reconnectColor: remoteReconnectColor,
                    fontScale: fontScale,
                    topPadding: remoteTopPadding,
                    onReconnect: onReconnect
                )
            }

            SidebarWorkspaceDetailsStack(
                snapshot: snapshot,
                detailVisibility: detailVisibility,
                isActive: isActive,
                activeSecondaryColor: activeSecondaryColor,
                progressTrackColor: progressTrackColor,
                progressFillColor: progressFillColor,
                branchSecondaryColor: branchSecondaryColor,
                branchIconColor: branchIconColor,
                usesVerticalBranchLayout: usesVerticalBranchLayout,
                stacksBranchAndDirectory: stacksBranchAndDirectory,
                showsGitBranchIcon: showsGitBranchIcon,
                pullRequestForegroundColor: pullRequestForegroundColor,
                makesPullRequestsClickable: makesPullRequestsClickable,
                fontScale: fontScale,
                onFocus: onFocus,
                pullRequestStatusLabel: pullRequestStatusLabel,
                pullRequestOpenTooltip: pullRequestOpenTooltip,
                onOpenPullRequest: onOpenPullRequest,
                portLabel: portLabel,
                portTooltip: portTooltip,
                onOpenPort: onOpenPort
            )
        }
    }
}
