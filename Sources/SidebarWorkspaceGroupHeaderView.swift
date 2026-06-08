import AppKit
import SwiftUI

/// Collapsible group header that doubles as the anchor workspace row.
struct SidebarWorkspaceGroupHeaderView: View, Equatable {
    // Closures and delegate factories are excluded because they are recreated
    // by the parent on each evaluation. The scalar snapshots below are the
    // header's render and behavior inputs under the LazyVStack.
    nonisolated static func == (lhs: SidebarWorkspaceGroupHeaderView, rhs: SidebarWorkspaceGroupHeaderView) -> Bool {
        lhs.groupId == rhs.groupId &&
            lhs.anchorWorkspaceId == rhs.anchorWorkspaceId &&
            lhs.name == rhs.name &&
            lhs.iconSymbol == rhs.iconSymbol &&
            lhs.tintHex == rhs.tintHex &&
            lhs.isCollapsed == rhs.isCollapsed &&
            lhs.isPinned == rhs.isPinned &&
            lhs.isAnchorActive == rhs.isAnchorActive &&
            lhs.memberCount == rhs.memberCount &&
            lhs.anchorUnreadCount == rhs.anchorUnreadCount &&
            lhs.shortcutDigit == rhs.shortcutDigit &&
            lhs.shortcutModifierSymbol == rhs.shortcutModifierSymbol &&
            lhs.showsShortcutHint == rhs.showsShortcutHint &&
            lhs.shortcutHintXOffset == rhs.shortcutHintXOffset &&
            lhs.shortcutHintYOffset == rhs.shortcutHintYOffset &&
            lhs.fontScale == rhs.fontScale &&
            lhs.cwdContextMenuItems == rhs.cwdContextMenuItems &&
            lhs.newWorkspacePlacement == rhs.newWorkspacePlacement &&
            lhs.rowSpacing == rhs.rowSpacing &&
            lhs.isFirstRow == rhs.isFirstRow &&
            lhs.isBeingDragged == rhs.isBeingDragged &&
            lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible
    }

    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    let tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let memberCount: Int
    let anchorUnreadCount: Int
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String?
    let showsShortcutHint: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let onDragStart: () -> NSItemProvider
    let tabDropDelegateFactory: (CGFloat) -> SidebarWorkspaceGroupHeaderDropDelegate
    let onToggleCollapsed: () -> Void
    let onFocusAnchor: () -> Void
    let onTapPlus: () -> Void
    let onRunResolvedItem: (CmuxResolvedConfigMenuAction) -> Void
    let onRename: () -> Void
    let onTogglePinned: () -> Void
    let onUngroup: () -> Void
    let onDelete: () -> Void
    let onEditConfig: () -> Void
    let onOpenDocs: () -> Void

    @State private var isHovered = false
    @State private var rowHeight: CGFloat = 1

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    private var iconColor: Color {
        if let tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return .secondary
    }

    private var displayedIconSymbol: String {
        RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: iconSymbol, configured: nil)
    }

    private var shortcutHintPillText: String? {
        guard showsShortcutHint,
              let shortcutDigit,
              let shortcutModifierSymbol else { return nil }
        return "\(shortcutModifierSymbol)\(shortcutDigit)"
    }

    private var rowHeightProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    rowHeight = max(proxy.size.height, 1)
                }
                .onChange(of: proxy.size.height) { _, newHeight in
                    rowHeight = max(newHeight, 1)
                }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: metrics.chevronFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
                .contentShape(Rectangle())
                .onTapGesture { onToggleCollapsed() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    Text(
                        isCollapsed
                            ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                            : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
                    )
                )

            HStack(spacing: 6) {
                Image(systemName: displayedIconSymbol)
                    .font(.system(size: metrics.iconFontSize, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: metrics.nameFontSize, weight: .semibold))
                    .foregroundStyle(isAnchorActive ? Color.primary : Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if anchorUnreadCount > 0 {
                    Text("\(anchorUnreadCount)")
                        .font(.system(size: metrics.unreadFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.unreadHorizontalPadding)
                        .padding(.vertical, metrics.unreadVerticalPadding)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                            anchorUnreadCount
                        )))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onFocusAnchor() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(name))
            .accessibilityHint(Text(String(
                localized: "workspaceGroup.focusAnchor.a11y",
                defaultValue: "Focus the group's anchor workspace"
            )))

            let plusVisible = isHovered && !showsShortcutHint
            Button(action: onTapPlus) {
                Image(systemName: "plus")
                    .font(.system(size: metrics.plusFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.plusFrame, height: metrics.plusFrame)
                    .contentShape(Rectangle())
                    .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.plusFrame, height: metrics.plusFrame)
            .allowsHitTesting(plusVisible)
            .accessibilityHidden(!plusVisible)
            .accessibilityLabel(Text(String(
                localized: "workspaceGroup.newWorkspaceInGroup.a11y",
                defaultValue: "New workspace in group"
            )))
            .contextMenu {
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                        defaultValue: "New Workspace in Group"
                    ),
                    action: onTapPlus
                )
                if !cwdContextMenuItems.isEmpty {
                    Divider()
                    ForEach(cwdContextMenuItems) { item in
                        switch item {
                        case .separator:
                            Divider()
                        case .action(let action):
                            Button(action.title) {
                                onRunResolvedItem(action)
                            }
                        }
                    }
                }
                Divider()
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.editConfig",
                        defaultValue: "Edit Group Config..."
                    ),
                    action: onEditConfig
                )
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.openDocs",
                        defaultValue: "Open Workspace Groups Docs"
                    ),
                    action: onOpenDocs
                )
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            isAnchorActive
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .sidebarShortcutHintOverlay(
            text: shortcutHintPillText,
            emphasis: isAnchorActive ? 1.0 : 0.9,
            offsetX: shortcutHintXOffset,
            offsetY: shortcutHintYOffset
        )
        .padding(.horizontal, 6)
        .background { rowHeightProbe }
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: isFirstRow,
                rowSpacing: rowSpacing
            )
        }
        .onDrag(onDragStart)
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegateFactory(rowHeight))
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.rename",
                    defaultValue: "Rename Group..."
                ),
                action: onRename
            )
            Button(
                isPinned
                    ? String(
                        localized: "workspaceGroup.contextMenu.unpin",
                        defaultValue: "Unpin Group"
                    )
                    : String(
                        localized: "workspaceGroup.contextMenu.pin",
                        defaultValue: "Pin Group"
                    ),
                action: onTogglePinned
            )
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.editConfig",
                    defaultValue: "Edit Group Config..."
                ),
                action: onEditConfig
            )
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.openDocs",
                    defaultValue: "Open Workspace Groups Docs"
                ),
                action: onOpenDocs
            )
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.ungroup",
                    defaultValue: "Ungroup (Keep Workspaces)"
                ),
                action: onUngroup
            )
            Button(
                role: .destructive,
                action: onDelete
            ) {
                Text(
                    String(
                        localized: "workspaceGroup.contextMenu.delete",
                        defaultValue: "Delete Group (Close Workspaces)"
                    )
                )
            }
        }
    }
}

enum SidebarWorkspaceGroupHeaderDropZone {
    static func isCenterDrop(locationY: CGFloat, rowHeight: CGFloat) -> Bool {
        let height = max(rowHeight, 1)
        let edgeBand = min(max(height * 0.25, 4), height * 0.4)
        let y = min(max(locationY, 0), height)
        return y > edgeBand && y < height - edgeBand
    }
}

enum SidebarWorkspaceGroupHeaderDropAction: Equatable {
    case addWorkspaceToGroup(UUID)
    case noOp
}

enum SidebarWorkspaceGroupHeaderDropPolicy {
    static func action(
        hasSidebarPayload: Bool,
        draggedWorkspaceId: UUID?,
        draggedWorkspaceIsPinned: Bool,
        draggedWorkspaceGroupId: UUID?,
        draggedWorkspaceIsGroupAnchor: Bool,
        targetGroupId: UUID,
        targetAnchorWorkspaceId: UUID,
        targetAnchorMatchesGroup: Bool,
        locationY: CGFloat,
        rowHeight: CGFloat
    ) -> SidebarWorkspaceGroupHeaderDropAction? {
        guard hasSidebarPayload,
              let draggedWorkspaceId,
              targetAnchorMatchesGroup,
              SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(
                  locationY: locationY,
                  rowHeight: rowHeight
              ) else {
            return nil
        }
        if draggedWorkspaceId == targetAnchorWorkspaceId || draggedWorkspaceGroupId == targetGroupId {
            return .noOp
        }
        guard !draggedWorkspaceIsPinned,
              !draggedWorkspaceIsGroupAnchor else {
            return nil
        }
        return .addWorkspaceToGroup(draggedWorkspaceId)
    }

    static func shouldConsumeNoOpEdgeDrop(
        hasSidebarPayload: Bool,
        draggedWorkspaceId: UUID?,
        draggedWorkspaceGroupId: UUID?,
        targetGroupId: UUID,
        targetAnchorWorkspaceId: UUID,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        locationY: CGFloat,
        rowHeight: CGFloat
    ) -> Bool {
        guard hasSidebarPayload,
              let draggedWorkspaceId,
              tabIds.count > 1,
              tabIds.contains(draggedWorkspaceId),
              tabIds.contains(targetAnchorWorkspaceId),
              !SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(
                  locationY: locationY,
                  rowHeight: rowHeight
              ) else {
            return false
        }
        if draggedWorkspaceId == targetAnchorWorkspaceId || draggedWorkspaceGroupId == targetGroupId {
            return true
        }
        return SidebarDropPlanner.indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: targetAnchorWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: locationY,
            targetHeight: rowHeight
        ) == nil
    }
}

@MainActor
struct SidebarWorkspaceGroupHeaderDropDelegate: DropDelegate {
    let targetGroupId: UUID
    let targetAnchorWorkspaceId: UUID
    let tabManager: TabManager
    let dragState: SidebarDragState
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    let reorderDelegate: SidebarTabDropDelegate

    func validateDrop(info: DropInfo) -> Bool {
        reorderDelegate.validateDrop(info: info) || groupHeaderCenterDropAction(info) != nil
    }

    func dropEntered(info: DropInfo) {
        if updateGroupHeaderCenterDrop(info) { return }
        reorderDelegate.dropEntered(info: info)
    }

    func dropExited(info: DropInfo) {
        reorderDelegate.dropExited(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if updateGroupHeaderCenterDrop(info) {
            return DropProposal(operation: .move)
        }
        return reorderDelegate.dropUpdated(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let action = groupHeaderCenterDropAction(info) else {
            if shouldConsumeGroupHeaderNoOpEdgeDrop(info) {
                clearDropState()
                return true
            }
            return reorderDelegate.performDrop(info: info)
        }
        defer { clearDropState() }
        switch action {
        case .addWorkspaceToGroup(let draggedTabId):
            tabManager.addWorkspaceToGroup(workspaceId: draggedTabId, groupId: targetGroupId)
        case .noOp:
            break
        }
        return true
    }

    private func updateGroupHeaderCenterDrop(_ info: DropInfo) -> Bool {
        guard groupHeaderCenterDropAction(info) != nil else { return false }
        dragAutoScrollController.updateFromDragLocation()
        dragState.clearDropIndicator()
        return true
    }

    private func groupHeaderCenterDropAction(_ info: DropInfo) -> SidebarWorkspaceGroupHeaderDropAction? {
        guard let draggedTabId = dragState.draggedTabId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }),
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }) else {
            return nil
        }
        return SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
            draggedWorkspaceId: draggedTabId,
            draggedWorkspaceIsPinned: draggedTab.isPinned,
            draggedWorkspaceGroupId: draggedTab.groupId,
            draggedWorkspaceIsGroupAnchor: tabManager.workspaceGroups.contains {
                $0.anchorWorkspaceId == draggedTabId
            },
            targetGroupId: targetGroupId,
            targetAnchorWorkspaceId: targetAnchorWorkspaceId,
            targetAnchorMatchesGroup: group.anchorWorkspaceId == targetAnchorWorkspaceId,
            locationY: info.location.y,
            rowHeight: targetRowHeight ?? 1
        )
    }

    private func shouldConsumeGroupHeaderNoOpEdgeDrop(_ info: DropInfo) -> Bool {
        let height = targetRowHeight ?? 1
        guard let draggedTabId = dragState.draggedTabId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }) else { return false }
        return SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
            draggedWorkspaceId: draggedTabId,
            draggedWorkspaceGroupId: draggedTab.groupId,
            targetGroupId: targetGroupId,
            targetAnchorWorkspaceId: targetAnchorWorkspaceId,
            tabIds: tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetAnchorWorkspaceId
            ),
            pinnedTabIds: tabManager.sidebarReorderPinnedWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetAnchorWorkspaceId
            ),
            locationY: info.location.y,
            rowHeight: height
        )
    }

    private func clearDropState() {
        dragState.clearDrag()
        dragAutoScrollController.stop()
    }
}
