import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Bonsplit
import Combine
import CmuxSidebarInterpreterClient
import CmuxTerminal
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettingsUI
import CmuxSidebar
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

// PERF: TabItemView is an Equatable value projection. The parent owns every
// workspace/store observation and passes one immutable render snapshot plus a
// closure capability bundle. No live model, binding, or observable store may
// cross this LazyVStack boundary (#6707 / #2586).
struct TabItemView: View, Equatable {
    nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    @Environment(\.colorScheme) private var colorScheme
    // Global font magnification percent, read once per row instead of through a
    // per-label `CmuxFontModifier`. Each `.cmuxFont(...)` is a custom
    // `@Environment`-reading `ViewModifier`; with 100+ workspaces continuously
    // re-rendering rows under agent churn, ~20 of those per row multiplied the
    // SwiftUI `DynamicBody`/environment node count the sidebar must re-evaluate
    // on every render pass (issue #6612, regression from #6554). Reading the
    // percent here and applying a primitive `.font(...)` keeps magnification
    // working while dropping those per-label modifier bodies.
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
#if DEBUG
    // Plain-value environment probe (closure struct, not an object reference):
    // set only by SidebarLazyLayoutScaleTests, default no-op, excluded from ==
    // like all closures. See SidebarLazyContractProbe.
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif
    let snapshot: SidebarWorkspaceRowSnapshot
    let actions: SidebarWorkspaceRowActions

    @State private var contextMenuVisible = false
    @State var workspaceFinderDirectoryOpenRequest: WorkspaceFinderDirectoryOpenRequest?
    @State private var isEditing = false
    @State private var renameDraft = ""
    @State private var renameBaselineHadUserCustomTitle = false

    private static let maxWrappedTitleLines = 8
    private static let maxDisplayedTitleCharacters = 2048

    var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot { snapshot.workspace }
    var workspaceId: UUID { snapshot.workspaceId }
    var index: Int { snapshot.index }
    var isActive: Bool { snapshot.isActive }
    var isMultiSelected: Bool { snapshot.isMultiSelected }
    var workspaceShortcutDigit: Int? { snapshot.workspaceShortcutDigit }
    var workspaceShortcutModifierSymbol: String { snapshot.workspaceShortcutModifierSymbol }
    var canCloseWorkspace: Bool { snapshot.canCloseWorkspace }
    var accessibilityWorkspaceCount: Int { snapshot.workspaceCount }
    var unreadCount: Int { snapshot.unreadCount }
    var latestNotificationText: String? { snapshot.latestNotificationText }
    var showsAgentActivity: Bool { snapshot.showsAgentActivity }
    var rowSpacing: CGFloat { snapshot.rowSpacing }
    var showsModifierShortcutHints: Bool { snapshot.showsModifierShortcutHints }
    var isPointerHovering: Bool { snapshot.isPointerHovering }
    var isBeingDragged: Bool { snapshot.isBeingDragged }
    var topDropIndicatorVisible: Bool { snapshot.topDropIndicatorVisible }
    var bottomDropIndicatorVisible: Bool { snapshot.bottomDropIndicatorVisible }
    var contextMenuWorkspaceIds: [UUID] { snapshot.contextMenu.targetWorkspaceIds }
    var settings: SidebarTabItemSettingsSnapshot { snapshot.settings }
    var isChecklistExpanded: Bool { snapshot.isChecklistExpanded }
    var checklistAddFieldActivationToken: Int { snapshot.checklistAddFieldActivationToken }
    var isChecklistPopoverPresented: Bool { snapshot.isChecklistPopoverPresented }

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

    private var sidebarBranchLayout: SidebarWorkspaceBranchDirectorySettings.BranchLayout {
        settings.branchDirectory.branchLayout
    }

    private var sidebarBranchDirectoryPlacement: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement {
        settings.branchDirectory.branchDirectoryPlacement
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

    private var activeTabIndicatorStyle: WorkspaceIndicatorStyle {
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

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var fontScale: CGFloat {
        settings.sidebarFontScale
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    /// Resolves a system font scaled by the global magnification percent,
    /// matching `CmuxFontModifier` exactly but without introducing a per-label
    /// custom `ViewModifier` (and its `@Environment` attribute + `DynamicBody`)
    /// for each `Text` in the row. The row reads the magnification percent once
    /// (`globalFontMagnificationPercent`) and applies a primitive `.font(...)`,
    /// removing ~20 redundant modifier bodies per row from the sidebar render
    /// pass (issue #6612).
    private func magnifiedFont(
        _ baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> Font {
        var font = Font.system(
            size: GlobalFontMagnification.scaledSize(baseSize, percent: globalFontMagnificationPercent),
            weight: weight,
            design: design
        )
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private func showsLeadingRail(
        for workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    ) -> Bool {
        explicitRailColor(for: workspaceSnapshot) != nil
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
        isPointerHovering
            && !contextMenuVisible
            && canCloseWorkspace
            && !(showsModifierShortcutHints || alwaysShowShortcutHints)
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    @ViewBuilder
    private func remoteWorkspaceSection(
        snapshot workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    ) -> some View {
        if !settings.hidesAllDetails, sidebarShowSSH, let remoteWorkspaceSidebarText = workspaceSnapshot.remoteWorkspaceSidebarText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(remoteWorkspaceSidebarText)
                        .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Text(workspaceSnapshot.remoteConnectionStatusText)
                        .font(magnifiedFont(scaledFontSize(9), weight: .medium))
                        .foregroundColor(activeSecondaryColor(0.58))
                        .lineLimit(1)

                    if workspaceSnapshot.showsRemoteReconnectAffordance {
                        Button {
                            actions.reconnectTargets([workspaceId])
                        } label: {
                            Label(
                                String(localized: "sidebar.remote.reconnect.button", defaultValue: "Reconnect"),
                                systemImage: "arrow.clockwise"
                            )
                            .labelStyle(.titleAndIcon)
                            .font(magnifiedFont(scaledFontSize(9), weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(activeSecondaryColor(0.9))
                        .safeHelp(String(
                            format: String(
                                localized: "sidebar.remote.reconnect.help",
                                defaultValue: "Reconnect to %@"
                            ),
                            locale: .current,
                            remoteWorkspaceSidebarText
                        ))
                    }
                }
            }
            .padding(.top, latestNotificationText == nil ? 1 : 2)
            .safeHelp(workspaceSnapshot.remoteStateHelpText)
        }
    }

    func copyWorkspaceIdsToPasteboard(_ ids: [UUID], includeRefs: Bool = false) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(ids, includeRefs: includeRefs)
    }

    func copyWorkspaceLinksToPasteboard(_ ids: [UUID]) {
        actions.copyWorkspaceLinks(ids)
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    var body: some View {
#if DEBUG
        let _ = { sidebarLazyContractProbe.workspaceRowBody?() }()
#endif
        let signpost = SidebarProfilingSignposts.begin("sidebar-tab-item-body", "index=\(index) workspace=\(workspaceId.uuidString.prefix(5)) active=\(isActive) unread=\(unreadCount)")
        let workspaceSnapshot = self.workspaceSnapshot
        let rowBackgroundColor = backgroundColor(for: workspaceSnapshot)
        let rowRailColor = railColor(for: workspaceSnapshot)
        let accessibilityTitle = workspaceSnapshot.accessibilityLabel(index: index, workspaceCount: accessibilityWorkspaceCount)
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        let closeButtonTooltip = workspaceSnapshot.isPinned ? protectedWorkspaceTooltip : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        let latestNotificationSubtitle = latestNotificationText
        let conversationMessageSubtitle = !settings.hidesAllDetails && settings.iMessageModeEnabled
            ? workspaceSnapshot.latestConversationMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil
        let effectiveSubtitle = latestNotificationSubtitle ?? conversationMessageSubtitle
        let subtitleLineLimit = latestNotificationSubtitle == nil ? 2 : settings.notificationMessageLineLimit
        // Bound notification payloads before shaping so pathological text stays cheap in lazy, Equatable rows.
        let displayedSubtitle = effectiveSubtitle?.sidebarBoundedDisplayString(maxDisplayedLines: subtitleLineLimit, maxDisplayedCharacters: 4096)
        let detailVisibility = visibleAuxiliaryDetails
        let titleLineLimit = settings.wrapsWorkspaceTitles ? Self.maxWrappedTitleLines : 1
        let displayedTitle = workspaceSnapshot.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: Self.maxDisplayedTitleCharacters
        )
        let scaledUnreadBadgeSize = 16 * fontScale
        let scaledLoadingSpinnerSize = max(10, 12 * fontScale)
        let titleFirstLineCenter = GlobalFontMagnification.scaledSize(
            scaledFontSize(12.5),
            percent: globalFontMagnificationPercent
        ) * 0.6
        let todoControlsEnabled = WorkspaceTodoFeature.isEnabled
        let scaledCloseButtonHitSize = max(16, 16 * fontScale)
        let scaledCloseButtonWidth = max(
            SidebarTrailingAccessoryWidthPolicy().closeButtonWidth,
            scaledCloseButtonHitSize
        )

        let showsLoadingSpinner = showsAgentActivity && workspaceSnapshot.activeCodingAgentCount > 0
        let badgeOnLeading = unreadCount > 0 && settings.notificationBadgePosition == .leading
        let badgeOnTrailing = unreadCount > 0 && settings.notificationBadgePosition == .trailing
        let spinnerOnLeading = showsLoadingSpinner && settings.loadingSpinnerPosition == .leading
        let spinnerOnTrailing = showsLoadingSpinner && settings.loadingSpinnerPosition == .trailing
        let leadingSlotActive = badgeOnLeading || spinnerOnLeading
        let trailingStatusActive = badgeOnTrailing || spinnerOnTrailing
        let titleRowSpacing: CGFloat = spinnerOnLeading ? 6 : 8
        let badgeFont = magnifiedFont(scaledFontSize(9), weight: .semibold)
        let spinnerTooltip = SidebarWorkspaceLoadingTooltip.text(count: workspaceSnapshot.activeCodingAgentCount)
        let spinnerColor = usesInvertedActiveForeground ? selectedWorkspaceForegroundNSColor(opacity: 0.55) : .secondaryLabelColor
        let rowView = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .sidebarTitleFirstLineCenter, spacing: titleRowSpacing) {

                if leadingSlotActive {
                    SidebarWorkspaceLeadingStatusSlot(showsBadge: badgeOnLeading, showsSpinner: spinnerOnLeading, unreadCount: unreadCount, side: badgeOnLeading ? scaledUnreadBadgeSize : scaledLoadingSpinnerSize, spinnerSide: scaledLoadingSpinnerSize, badgeFont: badgeFont, badgeFillColor: activeUnreadBadgeFillColor, badgeTextColor: activeUnreadBadgeTextColor, spinnerColor: spinnerColor, spinnerTooltip: spinnerTooltip)
                }

                if workspaceSnapshot.isPinned {
                    CmuxSystemSymbolImage(magnified: "pin.fill", pointSize: scaledFontSize(9), weight: .semibold, tint: activeSecondaryColor(0.8))
                        .safeHelp(protectedWorkspaceTooltip)
                }

                if workspaceSnapshot.isMuted {
                    CmuxSystemSymbolImage(magnified: "bell.slash.fill", pointSize: scaledFontSize(9), weight: .semibold, tint: activeSecondaryColor(0.8))
                        .safeHelp(String(localized: "sidebar.mutedWorkspace.tooltip", defaultValue: "Notifications muted for this workspace"))
                }

                // Chrome-style media-activity glyphs: a noisy or capturing
                // background browser pane is surfaced on its workspace row,
                // styled like the pin indicator. Audio is the must-have signal;
                // mic/camera follow the macOS orange/green convention.
                SidebarMediaActivityIndicators(
                    mediaActivity: workspaceSnapshot.mediaActivity,
                    symbolPointSize: scaledFontSize(9),
                    audioColor: activeSecondaryColor(0.8)
                )

                let manualTaskStatusIndicator = SidebarWorkspaceManualTaskStatusIndicatorModel(
                    featureEnabled: todoControlsEnabled,
                    taskStatus: workspaceSnapshot.taskStatus,
                    hasManualOverride: workspaceSnapshot.hasManualTaskStatus
                )
                if let taskStatus = workspaceSnapshot.taskStatus,
                   let statusMenuModel = workspaceSnapshot.todoStatusMenuModel,
                   manualTaskStatusIndicator.showsIndicator {
                    SidebarWorkspaceManualStatusIndicatorMenu(
                        status: taskStatus,
                        model: statusMenuModel,
                        workspaceId: workspaceId,
                        applyTodoStatus: actions.applyTodoStatus,
                        hideTodoStatus: actions.hideTodoStatus,
                        usesMonochrome: usesInvertedActiveForeground,
                        monochromeColor: activeSecondaryColor(0.8),
                        neutralColor: activeSecondaryColor(0.8),
                        fontScale: fontScale
                    )
                    .alignmentGuide(.sidebarTitleFirstLineCenter) { $0[VerticalAlignment.center] }
                    .transition(.opacity)
                }

                SidebarCloudWorkspaceBadgeView(label: detailVisibility.showsBranchDirectory ? workspaceSnapshot.cloudWorkspaceLabel : nil, pointSize: scaledFontSize(10), tint: activeSecondaryColor(0.7))

                if isEditing {
                    SidebarInlineRenameField(
                        initialText: renameDraft,
                        fontSize: GlobalFontMagnification.scaledSize(scaledFontSize(12.5), percent: globalFontMagnificationPercent), textColor: selectedWorkspaceForegroundNSColor(opacity: 1.0),
                        accessibilityLabel: String(
                            localized: "sidebar.workspace.rename.field.accessibilityLabel",
                            defaultValue: "Rename workspace"
                        ),
                        placeholder: String(
                            localized: "commandPalette.rename.workspacePlaceholder",
                            defaultValue: "Workspace name"
                        ),
                        onCommit: { newName in
                            if let title = SidebarInlineRenameCommit().titleToCommit(
                                draft: newName,
                                baseline: renameDraft,
                                baselineHadUserCustomTitle: renameBaselineHadUserCustomTitle
                            ) {
                                actions.setCustomTitle(title)
                            }
                            isEditing = false
                        },
                        onCancel: { isEditing = false }
                    )
                    .opacity(workspaceSnapshot.isMuted ? 0.6 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.sidebarTitleFirstLineCenter) { _ in titleFirstLineCenter }
                    .layoutPriority(1)
                } else {
                    Text(displayedTitle)
                        .font(magnifiedFont(scaledFontSize(12.5), weight: titleFontWeight))
                        .foregroundColor(activePrimaryTextColor)
                        .opacity(workspaceSnapshot.isMuted ? 0.6 : 1)
                        .lineLimit(titleLineLimit)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.sidebarTitleFirstLineCenter) { _ in titleFirstLineCenter }
                        .layoutPriority(1)
                }

                if trailingStatusActive || canCloseWorkspace {
                    SidebarWorkspaceTrailingStatusSlot(showsSpinner: spinnerOnTrailing, showsBadge: badgeOnTrailing, unreadCount: unreadCount, side: scaledUnreadBadgeSize, width: scaledCloseButtonWidth, height: scaledCloseButtonHitSize, badgeFont: badgeFont, badgeFillColor: activeUnreadBadgeFillColor, badgeTextColor: activeUnreadBadgeTextColor, spinnerColor: spinnerColor, spinnerTooltip: spinnerTooltip, canCloseWorkspace: canCloseWorkspace, showsCloseButton: showCloseButton, closeButtonTooltip: closeButtonTooltip, closeButtonColor: activeSecondaryColor(0.7), closeButtonFontSize: scaledFontSize(9), closeAction: actions.closeWorkspace)
                }
            }

            if let description = workspaceSnapshot.customDescription {
                SidebarWorkspaceDescriptionText(
                    markdown: description,
                    isActive: usesInvertedActiveForeground,
                    activeForegroundColor: activeSecondaryColor(0.84),
                    fontScale: fontScale
                )
            }

            if let subtitle = displayedSubtitle {
                Text(subtitle)
                    .font(magnifiedFont(scaledFontSize(10)))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(subtitleLineLimit)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let minimalTodoVisibility = SidebarWorkspaceTodoMinimalVisibility(
                itemCount: workspaceSnapshot.checklistItems.count,
                addFieldActivationToken: checklistAddFieldActivationToken,
                isPopoverPresented: isChecklistPopoverPresented,
                canAddItems: todoControlsEnabled
            )
            remoteWorkspaceSection(snapshot: workspaceSnapshot)

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
                    .transition(.opacity)
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
                    .transition(.opacity)
                }
            }

            if detailVisibility.showsLog, let latestLog = workspaceSnapshot.latestLog {
                HStack(alignment: .center, spacing: 4) {
                    CmuxSystemSymbolImage(magnified: logLevelIcon(latestLog.level), pointSize: scaledFontSize(8), tint: logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(magnifiedFont(scaledFontSize(10)))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity)
            }

            if detailVisibility.showsProgress, let progress = workspaceSnapshot.progress {
                VStack(alignment: .leading, spacing: 2) {
                    let progressFraction = CGFloat(max(0, min(progress.value, 1)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(activeProgressTrackColor)
                        Capsule()
                            .fill(activeProgressFillColor)
                            .scaleEffect(x: progressFraction, y: 1, anchor: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 3 * fontScale))

                    if let label = progress.label {
                        Text(label)
                            .font(magnifiedFont(scaledFontSize(9)))
                            .foregroundColor(activeSecondaryColor(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity)
            }

            // Branch + directory row
            if detailVisibility.showsBranchDirectory {
                if sidebarBranchLayout == .vertical {
                    if !workspaceSnapshot.branchDirectoryLines.isEmpty {
                        HStack(alignment: .top, spacing: 3) {
                            if sidebarShowGitBranchIcon, workspaceSnapshot.branchLinesContainBranch {
                                CmuxSystemSymbolImage(magnified: "arrow.triangle.branch", pointSize: scaledFontSize(9), tint: activeSecondaryColor(0.6))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(workspaceSnapshot.branchDirectoryLines.enumerated()), id: \.offset) { _, line in
                                    if sidebarBranchDirectoryPlacement == .stacked {
                                        if let branch = line.branch {
                                            Text(branch)
                                                .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
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
                                                    .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                                                    .foregroundColor(activeSecondaryColor(0.75))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            if line.branch != nil, !line.directoryCandidates.isEmpty {
                                                CmuxSystemSymbolImage(magnified: "circle.fill", pointSize: scaledFontSize(3), tint: activeSecondaryColor(0.6))
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
                } else if sidebarBranchDirectoryPlacement == .stacked,
                          (workspaceSnapshot.compactGitBranchSummaryText != nil
                           || !workspaceSnapshot.compactDirectoryCandidates.isEmpty) {
                    HStack(alignment: .top, spacing: 3) {
                        if sidebarShowGitBranchIcon, workspaceSnapshot.compactGitBranchSummaryText != nil {
                            CmuxSystemSymbolImage(magnified: "arrow.triangle.branch", pointSize: scaledFontSize(9), tint: activeSecondaryColor(0.6))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            if let branchRow = workspaceSnapshot.compactGitBranchSummaryText {
                                Text(branchRow)
                                    .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
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
                            CmuxSystemSymbolImage(magnified: "arrow.triangle.branch", pointSize: scaledFontSize(9), tint: activeSecondaryColor(0.6))
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
                        let rowContent = HStack(alignment: .center, spacing: 4) {
                            PullRequestStatusIcon(
                                status: pullRequest.status,
                                color: pullRequestForegroundColor,
                                fontScale: fontScale
                            )
                            Text(pullRequestTitle).underline(settings.makesPullRequestsClickable).lineLimit(1).truncationMode(.tail)
                            Text(pullRequestStatusLabel(pullRequest.status)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(magnifiedFont(scaledFontSize(10), weight: .semibold))
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
                .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                .foregroundColor(activeSecondaryColor(0.75))
                .lineLimit(1)
            }

            // Rendered whenever there is content, a pending add request, or an OPEN
            // popover — unmounting dismantles the popover's anchor mid-presentation.
            if minimalTodoVisibility.showsChecklistSection {
                SidebarWorkspaceChecklistSection(
                    items: workspaceSnapshot.checklistItems,
                    completedCount: workspaceSnapshot.checklistCompletedCount,
                    totalCount: workspaceSnapshot.checklistTotalCount,
                    firstUncheckedText: workspaceSnapshot.checklistFirstUncheckedText,
                    workspaceTitle: workspaceSnapshot.title,
                    isExpanded: isChecklistExpanded,
                    addFieldActivationToken: checklistAddFieldActivationToken,
                    usesPopoverPresentation: settings.workspaceTodoChecklistStyle == .popover,
                    isPopoverPresented: isChecklistPopoverPresented,
                    primaryColor: activeSecondaryColor(0.9),
                    secondaryColor: activeSecondaryColor(0.65),
                    summaryFont: magnifiedFont(scaledFontSize(10), weight: .semibold, monospacedDigit: true),
                    itemFont: magnifiedFont(scaledFontSize(10)),
                    fontScale: fontScale,
                    canAddItems: todoControlsEnabled,
                    onToggleExpansion: actions.onToggleChecklistExpansion,
                    onPopoverPresentedChange: actions.onChecklistPopoverPresentedChange,
                    onConsumeAddFieldActivation: actions.onConsumeChecklistAddFieldActivation,
                    actions: actions.checklist
                )
                .transition(.opacity)
            }
        }
        // Done rows read as settled: dim the row content (not the selection
        // background) to ~60%; hit-testing is unaffected by opacity.
        .opacity(workspaceSnapshot.taskStatus == .done ? 0.6 : 1)
        // No implicit .animation(value:) on agent-mutable fields: animating a
        // row-height change interpolates the LazyVStack's measured height over
        // every frame of the 0.2s curve, and with dozens of agent sessions some
        // row is always animating, so the sidebar-wide layout re-runs at display
        // refresh rate (#5764 / #5845). Lazy rows must be height-stable after
        // they appear; content changes now apply in one discrete layout pass.
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(activeBorderColor, lineWidth: activeBorderLineWidth)
                }
                .overlay(alignment: .leading) {
                    if showsLeadingRail(for: workspaceSnapshot) {
                        Capsule(style: .continuous)
                        .fill(rowRailColor)
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
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: index == 0,
                rowSpacing: rowSpacing
            )
        }
        .overlay(alignment: .bottom) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: bottomDropIndicatorVisible,
                isFirstRow: false,
                rowSpacing: rowSpacing,
                isBottomEdge: true
            )
        }
        .task(id: workspaceFinderDirectoryOpenRequest) {
            guard let request = workspaceFinderDirectoryOpenRequest else { return }
            await WorkspaceFinderDirectoryOpener.openInFinder(request.directoryURL)
            guard !Task.isCancelled, workspaceFinderDirectoryOpenRequest == request else { return }
            workspaceFinderDirectoryOpenRequest = nil
        }
        .onTapGesture {
            if !isEditing { updateSelection() }
        }
        .onAppear {
            actions.onPointerDragEligibilityChange(!isEditing)
        }
        .onChange(of: isEditing) { _, isEditing in
            actions.onPointerDragEligibilityChange(!isEditing)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !isEditing else { return }
                beginInlineRename()
            }
        )
        .safeHelp(workspaceSnapshot.title)
        .modifier(SidebarRowAccessibilityModifier(
            isEditing: isEditing,
            label: accessibilityTitle,
            hint: accessibilityHintText,
            moveUpLabel: moveUpActionText,
            moveDownLabel: moveDownActionText,
            onMoveUp: { moveBy(-1) },
            onMoveDown: { moveBy(1) }
        ))
        .contextMenu {
            TabItemWorkspaceContextMenuContent(row: self)
                .onAppear {
                    contextMenuVisible = true
                    actions.onContextMenuAppear()
                }
                .onDisappear {
                    contextMenuVisible = false
                    actions.onContextMenuDisappear()
                }
        }
        let _ = SidebarProfilingSignposts.end(signpost)
#if DEBUG
        let _ = { sidebarLazyContractProbe.workspaceRowBodyEnd?() }()
#endif
        rowView
    }
    private func beginInlineRename() {
        updateSelection()
        renameDraft = workspaceSnapshot.title
        renameBaselineHadUserCustomTitle = snapshot.hasUserCustomTitle
        isEditing = true
    }

    private func backgroundColor(
        for workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    ) -> Color {
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

    private func railColor(
        for workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    ) -> Color {
        explicitRailColor(for: workspaceSnapshot) ?? .clear
    }

    private func explicitRailColor(
        for workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    ) -> Color? {
        guard let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme
        ) else {
            return nil
        }
        return Color(nsColor: railColor).opacity(0.95)
    }

    func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    func moveBy(_ delta: Int) {
        actions.moveBy(delta)
    }

    private func updateSelection() {
        actions.select(NSEvent.modifierFlags)
    }

    private var pullRequestForegroundColor: Color {
        isActive ? activeSecondaryColor(0.75) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        actions.openPullRequest(url)
    }

    private func openPortLink(_ port: Int) {
        actions.openPort(port)
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
                CmuxSystemSymbolImage(magnified: "xmark.circle", pointSize: 7 * fontScale, weight: .regular, tint: color)
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

    func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        actions.applyColor(hex, targetIds)
    }

    func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = workspaceSnapshot.customColorHex ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        let response = alert.runCmuxModal(
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(workspaceId)
        ) { _ in
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
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
        _ = alert.runCmuxModal(
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(workspaceId)
        )
    }

    func promptRename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: snapshot.customTitle ?? workspaceSnapshot.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        let response = alert.runCmuxModal(
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(workspaceId)
        ) { _ in
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard response == .alertFirstButtonReturn else { return }
        actions.setCustomTitle(input.stringValue)
    }

    func beginWorkspaceDescriptionEditFromContextMenu() {
        actions.editDescription()
    }
}

extension String {
    func sidebarBoundedDisplayString(maxDisplayedLines: Int, maxDisplayedCharacters: Int) -> String {
        var result = ""
        result.reserveCapacity(maxDisplayedCharacters)
        var lineCount = 1
        var characterCount = 0
        var truncated = false

        for character in self {
            if characterCount >= maxDisplayedCharacters {
                truncated = true
                break
            }
            if character == "\n" {
                if lineCount >= maxDisplayedLines {
                    truncated = true
                    break
                }
                lineCount += 1
            }
            result.append(character)
            characterCount += 1
        }

        guard truncated else { return self }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : trimmed + "..."
    }
}

private struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(
                    entry: entry,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .cmuxFont(size: 10 * fontScale, weight: .semibold)
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map(\.sidebarDisplayText)
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}

private struct SidebarMetadataEntryRow: View {
    let entry: SidebarStatusEntry
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    var body: some View {
        Group {
            if let url = entry.url {
                Button {
                    onFocus()
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(alignment: .center, spacing: 4) {
            if let icon = iconView {
                // `emoji:` / `text:` icons are SwiftUI text and take the row
                // color from here; the SF Symbol branch bakes it as `tint`.
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            metadataText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .cmuxFont(size: 10 * fontScale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return activeForegroundColor
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? activeForegroundColor.opacity(0.84) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 9 * fontScale))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 8 * fontScale, weight: .semibold))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(CmuxSystemSymbolImage(
            magnified: symbolName,
            pointSize: 8 * fontScale,
            weight: .medium,
            tint: foregroundColor.opacity(0.95)
        ))
    }

    @ViewBuilder
    private func metadataText(underlined: Bool) -> some View {
        let display = entry.sidebarDisplayText
        if entry.format == .markdown,
           let parsed = try? AttributedString(
                markdown: display,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            let attributed = parsed.applyingSidebarRowLinkPolicy(
                activeForegroundColor: isActive ? foregroundColor : nil
            )
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        } else {
            Text(display)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }
}

private struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details") : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .cmuxFont(size: 10 * fontScale, weight: .semibold)
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleBlocks: [SidebarMetadataBlock] {
        guard !isExpanded, blocks.count > collapsedBlockLimit else { return blocks }
        return Array(blocks.prefix(collapsedBlockLimit))
    }

    private var shouldShowToggle: Bool {
        blocks.count > collapsedBlockLimit
    }
}

private struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    var body: some View {
        // Render inline (memoized) so the FIRST render is already attributed.
        // Parsing in onAppear into @State performed a guaranteed nil ->
        // attributed swap on every first appearance, changing the row's height
        // mid-scroll and re-feeding the sidebar-wide layout cycle (#5764).
        let displayMarkdown = Self.displayMarkdown(from: block.markdown)
        let renderedMarkdown = SidebarMetadataMarkdownRenderer.rendered(displayMarkdown)?
            .applyingSidebarRowLinkPolicy(
                activeForegroundColor: isActive ? activeForegroundColor : nil
            )
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(displayMarkdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .cmuxFont(size: 10 * fontScale)
        .multilineTextAlignment(.leading)
        .lineLimit(Self.maxDisplayedLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary
    }

    private static func displayMarkdown(from markdown: String) -> String {
        markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: maxDisplayedLines,
            maxDisplayedCharacters: maxDisplayedCharacters
        )
    }
}
