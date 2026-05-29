import AppKit
import SwiftUI

/// Collapsible group header that doubles as the anchor workspace row.
struct SidebarWorkspaceGroupHeaderView: View {
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
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
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

    private var iconColor: Color {
        if let tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return .secondary
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
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
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
                Image(systemName: iconSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isAnchorActive ? Color.primary : Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if anchorUnreadCount > 0 {
                    Text("\(anchorUnreadCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: 18, height: 18)
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
        reorderDelegate.validateDrop(info: info) || isGroupHeaderAddDrop(info)
    }

    func dropEntered(info: DropInfo) {
        if updateGroupHeaderAddDrop(info) { return }
        reorderDelegate.dropEntered(info: info)
    }

    func dropExited(info: DropInfo) {
        reorderDelegate.dropExited(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if updateGroupHeaderAddDrop(info) {
            return DropProposal(operation: .move)
        }
        return reorderDelegate.dropUpdated(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isGroupHeaderAddDrop(info),
              let draggedTabId = dragState.draggedTabId else {
            return reorderDelegate.performDrop(info: info)
        }
        defer {
            dragState.draggedTabId = nil
            dragState.dropIndicator = nil
            dragAutoScrollController.stop()
        }
        tabManager.addWorkspaceToGroup(workspaceId: draggedTabId, groupId: targetGroupId)
        return true
    }

    private func updateGroupHeaderAddDrop(_ info: DropInfo) -> Bool {
        guard isGroupHeaderAddDrop(info) else { return false }
        dragAutoScrollController.updateFromDragLocation()
        dragState.dropIndicator = nil
        return true
    }

    private func isGroupHeaderAddDrop(_ info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
              let draggedTabId = dragState.draggedTabId,
              draggedTabId != targetAnchorWorkspaceId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }),
              !draggedTab.isPinned,
              draggedTab.groupId != targetGroupId,
              !tabManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == draggedTabId }),
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }),
              group.anchorWorkspaceId == targetAnchorWorkspaceId else {
            return false
        }
        let rowHeight = max(targetRowHeight ?? 1, 1)
        let edgeBand = min(max(rowHeight * 0.25, 10), rowHeight / 2)
        let y = min(max(info.location.y, 0), rowHeight)
        return y > edgeBand && y < rowHeight - edgeBand
    }
}
