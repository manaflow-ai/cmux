import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

// PERF: TabItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every TabManager
// or NotificationStore publish causes ALL tab items to re-evaluate (~18% of
// main thread during typing). If you add new properties, update == below.
// Reactive workspace state inside the row must not rely on parent diffs alone:
// `.equatable()` can otherwise leave sidebar badges/details stale until an
// unrelated parent change sneaks through. Keep the workspace reference plain
// and bridge only sidebar-visible workspace changes into local state.
// Do NOT add @EnvironmentObject or new @Binding without updating ==.
// Do NOT remove .equatable() from the ForEach call site in VerticalTabsSidebar.
struct SidebarWorkspaceSnapshotBuilder {
    struct PresentationKey: Equatable {
        let showsWorkspaceDescription: Bool
        let usesVerticalBranchLayout: Bool
        let showsGitBranch: Bool
        let usesViewportAwarePath: Bool
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
        let copyableSidebarSSHError: String?
        let latestConversationMessage: String?
        let metadataEntries: [SidebarStatusEntry]
        let metadataBlocks: [SidebarMetadataBlock]
        let latestLog: SidebarLogEntry?
        let progress: SidebarProgressState?
        let compactGitBranchSummaryText: String?
        let compactDirectoryCandidates: [String]
        let compactBranchDirectoryCandidates: [String]
        let branchDirectoryLines: [VerticalBranchDirectoryLine]
        let branchLinesContainBranch: Bool
        let pullRequestRows: [PullRequestDisplay]
        let listeningPorts: [Int]

    }
}

private final class SidebarTabItemContextMenuState: ObservableObject {
    var hasDeferredWorkspaceObservationInvalidation = false
    var pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
}

struct TabItemView: View, Equatable {
    private static let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    private static let legacyVMWebSocketDescription = "VM WebSocket PTY"

    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tab === rhs.tab &&
        lhs.index == rhs.index &&
        lhs.isActive == rhs.isActive &&
        lhs.workspaceShortcutDigit == rhs.workspaceShortcutDigit &&
        lhs.workspaceShortcutModifierSymbol == rhs.workspaceShortcutModifierSymbol &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.latestNotificationText == rhs.latestNotificationText &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsModifierShortcutHints == rhs.showsModifierShortcutHints &&
        lhs.contextMenuWorkspaceIds == rhs.contextMenuWorkspaceIds &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.contextMenuPinState == rhs.contextMenuPinState &&
        lhs.workspaceGroupMenuSnapshot == rhs.workspaceGroupMenuSnapshot &&
        lhs.isBeingDragged == rhs.isBeingDragged &&
        lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
        lhs.settings == rhs.settings
    }

    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    let tab: Tab
    let index: Int
    let isActive: Bool
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsModifierShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Row receives precomputed drag/drop snapshot values + action closures
    // instead of an `@Observable` store reference. This keeps TabItemView in
    // compliance with the snapshot-boundary rule for views under a LazyVStack
    // (see CLAUDE.md). When drag state changes, the parent recomputes these
    // per-row snapshots and `==` skips re-render for rows whose snapshot is
    // unchanged.
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let onDragStart: () -> NSItemProvider
    /// Factory invoked from `body` with the row's measured `rowHeight`. Closure
    /// captures the parent's `dragState`, so TabItemView itself never holds an
    /// `@Observable` store reference (snapshot-boundary rule).
    let tabDropDelegateFactory: (CGFloat) -> SidebarTabDropDelegate
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let settings: SidebarTabItemSettingsSnapshot
    /// Called from this row's contextMenu.onAppear so the parent can freeze
    /// `showsModifierShortcutHints` to the value it last passed in. Prevents
    /// modifier-key transitions from flipping the badges on the row sitting
    /// behind the open context menu.
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void
    @State private var workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
    @StateObject private var contextMenuState = SidebarTabItemContextMenuState()
    @State private var rowInteractionState = SidebarWorkspaceRowInteractionState()
    @State private var rowHeight: CGFloat = 1
    @State private var workspaceFinderDirectoryCache = WorkspaceFinderDirectoryCache()
    @State private var workspaceFinderDirectoryOpenRequest: WorkspaceFinderDirectoryOpenRequest?

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    private var sidebarShortcutHintXOffset: Double {
        settings.sidebarShortcutHintXOffset
    }

    private var sidebarShortcutHintYOffset: Double {
        settings.sidebarShortcutHintYOffset
    }

    private var alwaysShowShortcutHints: Bool {
        settings.alwaysShowShortcutHints
    }

    private var sidebarShowGitBranch: Bool {
        settings.showsGitBranch
    }

    private var sidebarBranchVerticalLayout: Bool {
        settings.usesVerticalBranchLayout
    }

    private var sidebarStacksBranchAndDirectory: Bool {
        settings.stacksBranchAndDirectory
    }

    private var sidebarUsesLastSegmentPath: Bool {
        settings.usesLastSegmentPath
    }

    private var sidebarShowGitBranchIcon: Bool {
        settings.showsGitBranchIcon
    }

    private var sidebarShowSSH: Bool {
        settings.showsSSH
    }

    private var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot {
        if let workspaceSnapshotStorage,
           workspaceSnapshotStorage.presentationKey == workspaceSnapshotPresentationKey {
            return workspaceSnapshotStorage
        }
        return makeWorkspaceSnapshot()
    }

    private var activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        settings.activeTabIndicatorStyle
    }

    private var sidebarSelectionColorHex: String? {
        settings.selectionColorHex
    }

    private var sidebarNotificationBadgeColorHex: String? {
        settings.notificationBadgeColorHex
    }

    private var selectedWorkspaceBackgroundNSColor: NSColor {
        sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
    }

    private func selectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(
            on: selectedWorkspaceBackgroundNSColor,
            opacity: opacity
        )
    }

    private var openSidebarPullRequestLinksInCmuxBrowser: Bool {
        settings.openPullRequestLinksInCmuxBrowser
    }

    private var openSidebarPortLinksInCmuxBrowser: Bool {
        settings.openPortLinksInCmuxBrowser
    }

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var fontScale: CGFloat {
        settings.sidebarFontScale
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    private var showsLeadingRail: Bool {
        explicitRailColor != nil
    }

    private var activeBorderLineWidth: CGFloat {
        switch activeTabIndicatorStyle {
        case .leftRail:
            return 0
        case .solidFill:
            return isActive ? 1.5 : 0
        }
    }

    private var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch activeTabIndicatorStyle {
        case .leftRail:
            return .clear
        case .solidFill:
            return Color.primary.opacity(0.5)
        }
    }

    private var usesInvertedActiveForeground: Bool {
        isActive
    }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: 1.0))
            : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    private var activeUnreadBadgeFillColor: Color {
        if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return usesInvertedActiveForeground ? activePrimaryTextColor.opacity(0.25) : cmuxAccentColor()
    }

    private var activeUnreadBadgeTextColor: Color {
        usesInvertedActiveForeground ? activePrimaryTextColor : .white
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.8) : cmuxAccentColor()
    }

    private var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }

    private var showCloseButton: Bool {
        rowInteractionState.shouldShowCloseButton(
            canCloseWorkspace: canCloseWorkspace,
            shortcutHintModeActive: showsModifierShortcutHints || alwaysShowShortcutHints
        )
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var remoteWorkspaceSidebarText: String? {
        guard tab.hasActiveRemoteTerminalSessions else { return nil }
        let trimmedTarget = tab.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "SSH workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.remoteConnectionState == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = tab.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch tab.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .reconnecting:
            return String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        }
    }

    private var rowHeightProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    rowHeight = max(proxy.size.height, 1)
                }
                .onChange(of: proxy.size.height) { newHeight in
                    rowHeight = max(newHeight, 1)
                }
        }
    }

    @ViewBuilder
    private var remoteWorkspaceSection: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        if !settings.hidesAllDetails, sidebarShowSSH, let remoteWorkspaceSidebarText = workspaceSnapshot.remoteWorkspaceSidebarText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(remoteWorkspaceSidebarText)
                        .font(.system(size: scaledFontSize(10), design: .monospaced))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Text(workspaceSnapshot.remoteConnectionStatusText)
                        .font(.system(size: scaledFontSize(9), weight: .medium))
                        .foregroundColor(activeSecondaryColor(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.top, latestNotificationText == nil ? 1 : 2)
            .safeHelp(workspaceSnapshot.remoteStateHelpText)
        }
    }

    private func copyWorkspaceIdsToPasteboard(_ ids: [UUID], includeRefs: Bool = false) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(ids, includeRefs: includeRefs)
    }

    private func copyWorkspaceLinksToPasteboard(_ ids: [UUID]) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceLinks(ids)
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    private var workspaceSnapshotPresentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: sidebarBranchVerticalLayout,
            showsGitBranch: sidebarShowGitBranch,
            usesViewportAwarePath: sidebarUsesLastSegmentPath,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }

    var body: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        let closeButtonTooltip = workspaceSnapshot.isPinned
            ? protectedWorkspaceTooltip
            : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        let finderDirectoryPath = WorkspaceFinderDirectoryResolver.path(for: tab)
        let finderDirectoryCacheKey = WorkspaceFinderDirectoryCacheKey(path: finderDirectoryPath)
        let latestNotificationSubtitle = latestNotificationText
        let conversationMessageSubtitle = !settings.hidesAllDetails && settings.iMessageModeEnabled
            ? workspaceSnapshot.latestConversationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            : nil
        let effectiveSubtitle = latestNotificationSubtitle ?? conversationMessageSubtitle
        let detailVisibility = visibleAuxiliaryDetails
        let scaledUnreadBadgeSize = 16 * fontScale
        let scaledCloseButtonHitSize = max(16, 16 * fontScale)
        let scaledCloseButtonWidth = max(
            SidebarTrailingAccessoryWidthPolicy.closeButtonWidth,
            scaledCloseButtonHitSize
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(activeUnreadBadgeFillColor)
                        Text("\(unreadCount)")
                            .font(.system(size: scaledFontSize(9), weight: .semibold))
                            .foregroundColor(activeUnreadBadgeTextColor)
                    }
                    .frame(width: scaledUnreadBadgeSize, height: scaledUnreadBadgeSize)
                }

                if workspaceSnapshot.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: scaledFontSize(9), weight: .semibold))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .safeHelp(protectedWorkspaceTooltip)
                }

                Text(workspaceSnapshot.title)
                    .font(.system(size: scaledFontSize(12.5), weight: titleFontWeight))
                    .foregroundColor(activePrimaryTextColor)
                    .lineLimit(settings.wrapsWorkspaceTitles ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                // The close button is a sibling that always reserves its width
                // when the workspace is closable, so the title wraps/truncates
                // before this corner instead of flowing under the hover x. Its
                // visibility toggles via opacity so hover never re-lays-out the
                // row. (Matches the group-header plus-button pattern.)
                if canCloseWorkspace {
                    Button(action: {
                        #if DEBUG
                        cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=button")
                        #endif
                        tabManager.closeWorkspaceWithConfirmation(tab)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: scaledFontSize(9), weight: .medium))
                            .foregroundColor(activeSecondaryColor(0.7))
                            .frame(width: scaledCloseButtonWidth, height: scaledCloseButtonHitSize, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .safeHelp(closeButtonTooltip)
                    .opacity(showCloseButton ? 1 : 0)
                    .allowsHitTesting(showCloseButton)
                    .accessibilityHidden(!showCloseButton)
                }
            }

            if let description = workspaceSnapshot.customDescription {
                SidebarWorkspaceDescriptionText(
                    markdown: description,
                    isActive: usesInvertedActiveForeground,
                    activeForegroundColor: activeSecondaryColor(0.84),
                    fontScale: fontScale
                )
                .id(description)
            }

            if let subtitle = effectiveSubtitle {
                Text(subtitle)
                    .font(.system(size: scaledFontSize(10)))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            remoteWorkspaceSection

            if detailVisibility.showsMetadata {
                let metadataEntries = workspaceSnapshot.metadataEntries
                let metadataBlocks = workspaceSnapshot.metadataBlocks
                if !metadataEntries.isEmpty {
                    SidebarMetadataRows(
                        entries: metadataEntries,
                        isActive: usesInvertedActiveForeground,
                        activeForegroundColor: activeSecondaryColor(0.95),
                        activeSecondaryForegroundColor: activeSecondaryColor(0.65),
                        fontScale: fontScale,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !metadataBlocks.isEmpty {
                    SidebarMetadataMarkdownBlocks(
                        blocks: metadataBlocks,
                        isActive: usesInvertedActiveForeground,
                        activeForegroundColor: activeSecondaryColor(0.8),
                        activeSecondaryForegroundColor: activeSecondaryColor(0.65),
                        fontScale: fontScale,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if detailVisibility.showsLog, let latestLog = workspaceSnapshot.latestLog {
                HStack(spacing: 4) {
                    Image(systemName: logLevelIcon(latestLog.level))
                        .font(.system(size: scaledFontSize(8)))
                        .foregroundColor(logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(.system(size: scaledFontSize(10)))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if detailVisibility.showsProgress, let progress = workspaceSnapshot.progress {
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(activeProgressTrackColor)
                            Capsule()
                                .fill(activeProgressFillColor)
                                .frame(width: max(0, geo.size.width * CGFloat(progress.value)))
                        }
                    }
                    .frame(height: max(3, 3 * fontScale))

                    if let label = progress.label {
                        Text(label)
                            .font(.system(size: scaledFontSize(9)))
                            .foregroundColor(activeSecondaryColor(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Branch + directory row
            if detailVisibility.showsBranchDirectory {
                if sidebarBranchVerticalLayout {
                    if !workspaceSnapshot.branchDirectoryLines.isEmpty {
                        HStack(alignment: .top, spacing: 3) {
                            if sidebarShowGitBranchIcon, workspaceSnapshot.branchLinesContainBranch {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: scaledFontSize(9)))
                                    .foregroundColor(activeSecondaryColor(0.6))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(workspaceSnapshot.branchDirectoryLines.enumerated()), id: \.offset) { _, line in
                                    if sidebarStacksBranchAndDirectory {
                                        if let branch = line.branch {
                                            Text(branch)
                                                .font(.system(size: scaledFontSize(10), design: .monospaced))
                                                .foregroundColor(activeSecondaryColor(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        if !line.directoryCandidates.isEmpty {
                                            SidebarDirectoryText(
                                                candidates: line.directoryCandidates,
                                                color: activeSecondaryColor(0.75),
                                                fontScale: fontScale
                                            )
                                        }
                                    } else {
                                        HStack(spacing: 3) {
                                            if let branch = line.branch {
                                                Text(branch)
                                                    .font(.system(size: scaledFontSize(10), design: .monospaced))
                                                    .foregroundColor(activeSecondaryColor(0.75))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            if line.branch != nil, !line.directoryCandidates.isEmpty {
                                                Image(systemName: "circle.fill")
                                                    .font(.system(size: scaledFontSize(3)))
                                                    .foregroundColor(activeSecondaryColor(0.6))
                                                    .padding(.horizontal, 1)
                                            }
                                            if !line.directoryCandidates.isEmpty {
                                                SidebarDirectoryText(
                                                    candidates: line.directoryCandidates,
                                                    color: activeSecondaryColor(0.75),
                                                    fontScale: fontScale
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if sidebarStacksBranchAndDirectory,
                          (workspaceSnapshot.compactGitBranchSummaryText != nil
                           || !workspaceSnapshot.compactDirectoryCandidates.isEmpty) {
                    HStack(alignment: .top, spacing: 3) {
                        if sidebarShowGitBranchIcon, workspaceSnapshot.compactGitBranchSummaryText != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: scaledFontSize(9)))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            if let branchRow = workspaceSnapshot.compactGitBranchSummaryText {
                                Text(branchRow)
                                    .font(.system(size: scaledFontSize(10), design: .monospaced))
                                    .foregroundColor(activeSecondaryColor(0.75))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if !workspaceSnapshot.compactDirectoryCandidates.isEmpty {
                                SidebarDirectoryText(
                                    candidates: workspaceSnapshot.compactDirectoryCandidates,
                                    color: activeSecondaryColor(0.75),
                                    fontScale: fontScale
                                )
                            }
                        }
                    }
                } else if !workspaceSnapshot.compactBranchDirectoryCandidates.isEmpty {
                    HStack(spacing: 3) {
                        if sidebarShowGitBranchIcon, workspaceSnapshot.compactGitBranchSummaryText != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: scaledFontSize(9)))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        SidebarDirectoryText(
                            candidates: workspaceSnapshot.compactBranchDirectoryCandidates,
                            color: activeSecondaryColor(0.75),
                            fontScale: fontScale
                        )
                    }
                }
            }

            // Pull request rows
            if detailVisibility.showsPullRequests, !workspaceSnapshot.pullRequestRows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspaceSnapshot.pullRequestRows) { pullRequest in
                        let pullRequestNumber = String(pullRequest.number)
                        let pullRequestTitle = "\(pullRequest.label) #\(pullRequestNumber)"
                        let rowContent = HStack(spacing: 4) {
                            PullRequestStatusIcon(
                                status: pullRequest.status,
                                color: pullRequestForegroundColor,
                                fontScale: fontScale
                            )
                            Text(pullRequestTitle).underline(settings.makesPullRequestsClickable).lineLimit(1).truncationMode(.tail)
                            Text(pullRequestStatusLabel(pullRequest.status)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: scaledFontSize(10), weight: .semibold))
                        .foregroundColor(pullRequestForegroundColor)
                        .opacity(pullRequest.isStale ? 0.5 : 1)
                        if settings.makesPullRequestsClickable {
                            Button(action: { openPullRequestLink(pullRequest.url) }) { rowContent }
                                .buttonStyle(.plain)
                                .tint(pullRequestForegroundColor)
                                .safeHelp(String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(pullRequestTitle)"))
                                .accessibilityIdentifier("SidebarPullRequestRow")
                        } else {
                            rowContent.accessibilityElement(children: .combine).accessibilityIdentifier("SidebarPullRequestRow")
                        }
                    }
                }
            }

            // Ports row
            if detailVisibility.showsPorts, !workspaceSnapshot.listeningPorts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(workspaceSnapshot.listeningPorts, id: \.self) { port in
                        let portLabel = SidebarPortDisplayText.label(for: port)
                        let portTooltip = SidebarPortDisplayText.openTooltip(for: port)
                        Button(action: {
                            openPortLink(port)
                        }) {
                            Text(portLabel)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .safeHelp(portTooltip)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: scaledFontSize(10), design: .monospaced))
                .foregroundColor(activeSecondaryColor(0.75))
                .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: workspaceSnapshot.latestLog)
        .animation(.easeInOut(duration: 0.2), value: workspaceSnapshot.progress != nil)
        .animation(.easeInOut(duration: 0.2), value: workspaceSnapshot.metadataBlocks.count)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(activeBorderColor, lineWidth: activeBorderLineWidth)
                }
                .overlay(alignment: .leading) {
                    if showsLeadingRail {
                        Capsule(style: .continuous)
                            .fill(railColor)
                            .frame(width: 3)
                            .padding(.leading, 4)
                            .padding(.vertical, 5)
                            .offset(x: -1)
                    }
                }
        )
        .sidebarShortcutHintOverlay(
            text: showsWorkspaceShortcutHint ? workspaceShortcutLabel : nil,
            emphasis: shortcutHintEmphasis,
            offsetX: sidebarShortcutHintXOffset,
            offsetY: sidebarShortcutHintYOffset,
            fontSize: scaledFontSize(10)
        )
        .shortcutHintVisibilityAnimation(value: showsWorkspaceShortcutHint)
        .padding(.horizontal, 6)
        .background { rowHeightProbe }
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            SidebarWorkspaceRowHoverTracker(rowInteractionState: $rowInteractionState)
        }
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=middleClick")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: index == 0,
                rowSpacing: rowSpacing
            )
        }
        .onAppear {
            refreshWorkspaceSnapshot(force: true)
        }
        .task(id: finderDirectoryCacheKey) {
            let cache = await WorkspaceFinderDirectoryResolver.cache(for: finderDirectoryCacheKey)
            guard !Task.isCancelled else { return }
            workspaceFinderDirectoryCache = cache
        }
        .task(id: workspaceFinderDirectoryOpenRequest) {
            guard let request = workspaceFinderDirectoryOpenRequest else { return }
            await WorkspaceFinderDirectoryOpener.openInFinder(request.directoryURL)
            guard !Task.isCancelled, workspaceFinderDirectoryOpenRequest == request else { return }
            workspaceFinderDirectoryOpenRequest = nil
        }
        .onReceive(
            tab.sidebarImmediateObservationPublisher
                .receive(on: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            cmuxDebugLog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=immediate " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            refreshWorkspaceSnapshot()
        }
        .onReceive(
            tab.sidebarObservationPublisher
                .receive(on: RunLoop.main)
                // Prompt-time sidebar telemetry can arrive as a short burst
                // (pwd, branch, PR, shell state). Coalesce that burst so the
                // row redraws once with the settled state instead of blinking.
                .debounce(for: Self.workspaceObservationCoalesceInterval, scheduler: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            cmuxDebugLog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=debounced " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            refreshWorkspaceSnapshot()
        }
        .onChange(of: settings) { _ in
            refreshWorkspaceSnapshot(force: true)
        }
        .onDrag(onDragStart)
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegateFactory(rowHeight))
        .onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: SidebarBonsplitTabDropDelegate(
            targetWorkspaceId: tab.id,
            tabManager: tabManager,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        ))
        .onTapGesture {
            updateSelection()
        }
        .safeHelp(workspaceSnapshot.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityAction(named: Text(moveUpActionText)) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text(moveDownActionText)) {
            moveBy(1)
        }
        .contextMenu {
            workspaceContextMenu
                .onAppear {
                    rowInteractionState.contextMenuDidAppear()
                    contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
                    contextMenuState.pendingWorkspaceSnapshot = nil
                    onContextMenuAppear()
                }
                .onDisappear {
                    rowInteractionState.contextMenuDidDisappear()
                    onContextMenuDisappear()
                    flushDeferredWorkspaceObservationInvalidation()
                }
        }
    }

    private func refreshWorkspaceSnapshot(force: Bool = false) {
        let nextSnapshot = makeWorkspaceSnapshot()
        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: workspaceSnapshotStorage,
            next: nextSnapshot,
            force: force,
            contextMenuVisible: rowInteractionState.contextMenuVisible
        )

        if workspaceSnapshotStorage != decision.workspaceSnapshotStorage {
            workspaceSnapshotStorage = decision.workspaceSnapshotStorage
        }
        if contextMenuState.pendingWorkspaceSnapshot != decision.pendingWorkspaceSnapshot {
            contextMenuState.pendingWorkspaceSnapshot = decision.pendingWorkspaceSnapshot
        }
        if contextMenuState.hasDeferredWorkspaceObservationInvalidation != decision.hasDeferredWorkspaceObservationInvalidation {
            contextMenuState.hasDeferredWorkspaceObservationInvalidation = decision.hasDeferredWorkspaceObservationInvalidation
        }
    }

    private func flushDeferredWorkspaceObservationInvalidation() {
        guard contextMenuState.hasDeferredWorkspaceObservationInvalidation else { return }
        contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
        if let pendingSnapshot = contextMenuState.pendingWorkspaceSnapshot {
            workspaceSnapshotStorage = pendingSnapshot
        }
        contextMenuState.pendingWorkspaceSnapshot = nil
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    @ViewBuilder
    private var workspaceContextMenu: some View {
        let targetIds = contextMenuWorkspaceIds
        let isMulti = targetIds.count > 1
        let tabColorPalette = WorkspaceTabColorSettings.palette()
        let shouldPin = contextMenuPinState?.pinned ?? !tab.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let copyWorkspaceIDLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            isMulti: isMulti)
        let copyWorkspaceLinkLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        let finderDirectoryCacheKey = WorkspaceFinderDirectoryCacheKey(
            path: isMulti ? nil : WorkspaceFinderDirectoryResolver.path(for: tab)
        )
        let finderDirectoryURL = workspaceFinderDirectoryCache.url(for: finderDirectoryCacheKey)
        Button(pinLabel) {
            guard let contextMenuPinState else {
                NSSound.beep()
                return
            }
            let result = WorkspaceActionDispatcher.performPinAction(contextMenuPinState, in: tabManager)
            if result.changedWorkspaceIds.isEmpty {
                refreshWorkspaceSnapshot(force: true)
            }
            syncSelectionAfterMutation()
        }
        .disabled(contextMenuPinState == nil)

        workspaceGroupContextMenuSection(targetIds: targetIds, isMulti: isMulti)

        if let key = renameWorkspaceShortcut.keyEquivalent {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
            .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
        } else {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
        }

        if tab.hasCustomTitle {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                tabManager.clearCustomTitle(tabId: tab.id)
            }
        }

        if !isMulti {
            if let key = editWorkspaceDescriptionShortcut.keyEquivalent {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
                .keyboardShortcut(key, modifiers: editWorkspaceDescriptionShortcut.eventModifiers)
            } else {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
            }

            if tab.hasCustomDescription {
                Button(String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")) {
                    tabManager.clearCustomDescription(tabId: tab.id)
                }
            }

        }

        if !remoteContextMenuWorkspaceIds.isEmpty {
            Divider()

            Button(reconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.reconnectRemoteConnection()
                }
            }
            .disabled(allRemoteContextMenuTargetsConnecting)

            Button(disconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.disconnectRemoteConnection(clearConfiguration: false)
                }
            }
            .disabled(allRemoteContextMenuTargetsDisconnected)
        }

        Menu(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {
            if tab.customColor != nil {
                Button {
                    applyTabColor(nil, targetIds: targetIds)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }

            Button {
                promptCustomColor(targetIds: targetIds)
            } label: {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }

            if !tabColorPalette.isEmpty {
                Divider()
            }

            ForEach(tabColorPalette, id: \.id) { entry in
                Button {
                    applyTabColor(entry.hex, targetIds: targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: coloredCircleImage(color: tabColorSwatchColor(for: entry.hex)))
                    }
                }
            }
        }

        if let copyableSidebarSSHError = workspaceSnapshot.copyableSidebarSSHError {
            Button(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
                WorkspaceSurfaceIdentifierClipboardText.copy(copyableSidebarSSHError)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveBy(-1)
        }
        .disabled(index == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveBy(1)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            tabManager.moveTabsToTop(Set(targetIds))
            syncSelectionAfterMutation()
        }
        .disabled(targetIds.isEmpty)

        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveWorkspacesToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveWorkspaces(targetIds, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        if let key = closeWorkspaceShortcut.keyEquivalent {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .disabled(targetIds.isEmpty)
        }

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            closeOtherTabs(targetIds)
        }
        .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            closeTabsBelow(tabId: tab.id)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            closeTabsAbove(tabId: tab.id)
        }
        .disabled(index == 0)

        Divider()

        Button(markReadLabel) {
            markTabsRead(targetIds)
        }
        .disabled(!notificationStore.canMarkWorkspaceRead(forTabIds: targetIds))

        Button(markUnreadLabel) {
            markTabsUnread(targetIds)
        }
        .disabled(!notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds))

        Button(clearLatestNotificationLabel) {
            clearLatestNotifications(targetIds)
        }
        .disabled(!hasLatestNotifications(in: targetIds))

        Divider()

        Button(copyWorkspaceIDLabel) {
            copyWorkspaceIdsToPasteboard(targetIds)
        }
        .disabled(targetIds.isEmpty)

        Button(copyWorkspaceLinkLabel) {
            copyWorkspaceLinksToPasteboard(targetIds)
        }
        .disabled(targetIds.isEmpty)

        if !isMulti {
            Button(String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder")) {
                workspaceFinderDirectoryOpenRequest = WorkspaceFinderDirectoryOpenRequest(directoryURL: finderDirectoryURL)
            }
            .disabled(finderDirectoryURL == nil)
        }
    }

    private var backgroundColor: Color {
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
        guard let color = style.color else { return .clear }
        return Color(nsColor: color).opacity(style.opacity)
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme
        ) else {
            return nil
        }
        return Color(nsColor: railColor).opacity(0.95)
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private var accessibilityTitle: String {
        String(localized: "accessibility.workspacePosition", defaultValue: "\(workspaceSnapshot.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)")
    }

    private func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    private func updateSelection() {
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id
        #if DEBUG
        var modStr = ""
        if modifiers.contains(.command) { modStr += "cmd " }
        if modifiers.contains(.shift) { modStr += "shift " }
        if modifiers.contains(.option) { modStr += "opt " }
        if modifiers.contains(.control) { modStr += "ctrl " }
        cmuxDebugLog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif

        let workspaceIds = tabManager.tabs.map(\.id)
        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy.shiftClickAnchorIndex(
                existingAnchorIndex: lastSidebarSelectionIndex,
                selectedWorkspaceIds: selectedTabIds,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: workspaceIds
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            // Filter out workspaces hidden inside collapsed groups so a
            // Shift-click range never silently includes rows the user
            // can't see (e.g. clicking a collapsed group's anchor and
            // then Shift-clicking a row below would otherwise sweep
            // every collapsed child between them).
            let collapsedGroupIds: Set<UUID> = Set(
                tabManager.workspaceGroups
                    .filter { $0.isCollapsed }
                    .map(\.id)
            )
            let anchorIdsByGroup: [UUID: UUID] = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0.anchorWorkspaceId) }
            )
            let rangeIds = tabManager.tabs[lower...upper].compactMap { tab -> UUID? in
                if let gid = tab.groupId,
                   collapsedGroupIds.contains(gid),
                   anchorIdsByGroup[gid] != tab.id {
                    return nil
                }
                return tab.id
            }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }

        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy.anchorIndexAfterWorkspaceClick(
            isShiftClick: isShift,
            resolvedShiftAnchorIndex: shiftAnchorIndex,
            clickedIndex: index
        )
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forTabId: id)
        }
    }

    private func clearLatestNotifications(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.clearLatestNotification(forTabId: id)
        }
    }

    private func hasLatestNotifications(in targetIds: [UUID]) -> Bool {
        targetIds.contains { notificationStore.latestNotification(forTabId: $0) != nil }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private var remoteStateHelpText: String {
        let target = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.remoteConnectionState {
        case .connected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connected",
                    defaultValue: "SSH connected to %@"
                ),
                locale: .current,
                target
            )
        case .connecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connecting",
                    defaultValue: "SSH connecting to %@"
                ),
                locale: .current,
                target
            )
        case .reconnecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.reconnecting",
                    defaultValue: "SSH reconnecting to %@"
                ),
                locale: .current,
                target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "SSH error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return String(
                format: String(
                    localized: "sidebar.remote.help.error",
                    defaultValue: "SSH error for %@"
                ),
                locale: .current,
                target
            )
        case .disconnected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.disconnected",
                    defaultValue: "SSH disconnected from %@"
                ),
                locale: .current,
                target
            )
        }
    }

    private func makeWorkspaceSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? = (detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests)
            ? tab.sidebarOrderedPanelIds()
            : nil
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  sidebarShowGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectoryCandidates: [String] = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return compactDirectoryCandidatesList(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryCandidates = compactBranchDirectoryCandidatesList(
            gitSummary: compactGitBranchSummaryText,
            directoryCandidates: compactDirectoryCandidates
        )
        let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = {
            guard detailVisibility.showsBranchDirectory,
                  sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return verticalBranchDirectoryLines(orderedPanelIds: orderedPanelIds)
        }()
        let branchLinesContainBranch = sidebarShowGitBranch && branchDirectoryLines.contains { $0.branch != nil }
        let pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()

        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: workspaceSnapshotPresentationKey,
            title: tab.title,
            customDescription: settings.showsWorkspaceDescription ? sidebarVisibleCustomDescription : nil,
            isPinned: tab.isPinned,
            customColorHex: tab.customColor,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: tab.latestConversationMessage,
            metadataEntries: detailVisibility.showsMetadata ? tab.sidebarStatusEntriesInDisplayOrder() : [],
            metadataBlocks: detailVisibility.showsMetadata ? tab.sidebarMetadataBlocksInDisplayOrder() : [],
            latestLog: detailVisibility.showsLog ? tab.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? tab.progress : nil,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: detailVisibility.showsPorts ? tab.listeningPorts : []
        )
    }

    private var sidebarVisibleCustomDescription: String? {
        guard let description = tab.customDescription else { return nil }
        if tab.title.hasPrefix("vm:"),
           description.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyVMWebSocketDescription {
            return nil
        }
        return description
    }

    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }

        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }

        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }

        if orderedWorkspaceIds.count > 1 {
            for workspaceId in orderedWorkspaceIds.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: false)
            }
            if let finalWorkspaceId = orderedWorkspaceIds.last {
                _ = app.moveWorkspaceToWindow(workspaceId: finalWorkspaceId, windowId: newWindowId, focus: true)
            }
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    // latestNotificationText is now passed as a parameter from the parent view
    // to avoid subscribing to notificationStore changes in every TabItemView.

    // Builds the joined "branch · directory" candidates list for inline mode.
    // Each entry pairs the (fixed) git summary with one entry from the
    // directory candidates list, so ViewThatFits can choose how aggressively to
    // shorten the directory portion as the row width changes.
    private func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = gitBranchSummaryLines(orderedPanelIds: orderedPanelIds)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func gitBranchSummaryLines(orderedPanelIds: [UUID]) -> [String] {
        tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private func verticalBranchDirectoryLines(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        let useViewportAwarePath = sidebarUsesLastSegmentPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryCandidates: [String] = {
                guard let directory = entry.directory else { return [] }
                if useViewportAwarePath {
                    return SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? [] : [shortened]
            }()

            if branchText == nil && directoryCandidates.isEmpty {
                return nil
            }
            return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                branch: branchText,
                directoryCandidates: directoryCandidates
            )
        }
    }

    // Candidates for the inline-mode directory line, longest → shortest. When
    // viewport-aware truncation is off, returns a single element with each
    // panel directory shortened via `~/`. When on, walks per-path candidate
    // indices, bumping the rightmost path that can still shrink at each step.
    // Each emitted candidate differs from the previous by exactly one path
    // collapsing one level, so ViewThatFits sees a strictly monotone gradient
    // (`full|full`, `full|mid`, `full|leaf`, `mid|leaf`, `leaf|leaf`) — later
    // panels shrink before earlier ones, preserving the leading workspace dir
    // as long as the row width allows.
    private func compactDirectoryCandidatesList(orderedPanelIds: [UUID]) -> [String] {
        let home = SidebarPathFormatter.homeDirectoryPath
        let directories = tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        guard !directories.isEmpty else { return [] }

        if !sidebarUsesLastSegmentPath {
            let joined = directories
                .map { SidebarPathFormatter.shortenedPath($0, homeDirectoryPath: home) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }

        let perDirectoryCandidates: [[String]] = directories
            .map { SidebarPathFormatter.pathCandidates($0, homeDirectoryPath: home) }
            .filter { !$0.isEmpty }
        guard !perDirectoryCandidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: perDirectoryCandidates.count)
        var result: [String] = []
        while true {
            let pieces = zip(indices, perDirectoryCandidates).map { idx, candidates in
                candidates[idx]
            }
            let joined = pieces.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined {
                result.append(joined)
            }
            guard let bumpIdx = indices.indices.last(where: { indices[$0] < perDirectoryCandidates[$0].count - 1 }) else {
                break
            }
            indices[bumpIdx] += 1
        }
        return result
    }

    private func pullRequestDisplays(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                isStale: pullRequest.isStale
            )
        }
    }

    private var pullRequestForegroundColor: Color {
        isActive ? activeSecondaryColor(0.75) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openPortLink(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        updateSelection()
        if openSidebarPortLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info:
                return activeSecondaryColor(0.5)
            case .progress:
                return activeSecondaryColor(0.8)
            case .success:
                return activeSecondaryColor(0.9)
            case .warning:
                return activeSecondaryColor(0.9)
            case .error:
                return activeSecondaryColor(0.9)
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private struct PullRequestStatusIcon: View {
        let status: SidebarPullRequestStatus
        let color: Color
        var fontScale: CGFloat = 1
        private static let closedFrameSize: CGFloat = 12
        private static let customFrameSize: CGFloat = 13

        private var closedFrameSize: CGFloat {
            Self.closedFrameSize * fontScale
        }

        private var customFrameSize: CGFloat {
            Self.customFrameSize * fontScale
        }

        var body: some View {
            switch status {
            case .open:
                PullRequestOpenIcon(color: color)
                    .scaleEffect(fontScale)
                    .frame(width: customFrameSize, height: customFrameSize)
            case .merged:
                PullRequestMergedIcon(color: color)
                    .scaleEffect(fontScale)
                    .frame(width: customFrameSize, height: customFrameSize)
            case .closed:
                Image(systemName: "xmark.circle")
                    .font(.system(size: 7 * fontScale, weight: .regular))
                    .foregroundColor(color)
                    .frame(width: closedFrameSize, height: closedFrameSize)
            }
        }
    }

    private struct PullRequestOpenIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3.0, y: 4.8))
                    path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                    path.move(to: CGPoint(x: 4.8, y: 3.0))
                    path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                    path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.0, y: 9.2))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 11.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private struct PullRequestMergedIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4.6, y: 4.6))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                    path.addLine(to: CGPoint(x: 9.2, y: 7.0))

                    path.move(to: CGPoint(x: 4.6, y: 9.4))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 7.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        tabManager.applyWorkspaceColor(hex, toWorkspaceIds: targetIds)
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized, targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
    }

    private func beginWorkspaceDescriptionEditFromContextMenu() {
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }
}
