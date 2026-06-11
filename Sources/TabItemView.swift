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


struct TabItemView: View, Equatable {
    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) var colorScheme
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
    @State var workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
    @State var contextMenuState = SidebarTabItemContextMenuState()
    @State var rowInteractionState = SidebarWorkspaceRowInteractionState()
    @State var rowHeight: CGFloat = 1
    @State var workspaceFinderDirectoryCache = WorkspaceFinderDirectoryCache()
    @State var workspaceFinderDirectoryOpenRequest: WorkspaceFinderDirectoryOpenRequest?

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

}

