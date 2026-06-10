import AppKit
import SwiftUI

extension VerticalTabsSidebar {
    @ViewBuilder
    func sidebarWorkspaceGroupHeader(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let settings = renderContext.tabItemSettings
        let isAnchorActive = tabManager.selectedTabId == group.anchorWorkspaceId
        let anchorCwd = renderContext.workspaceById[group.anchorWorkspaceId]?.currentDirectory
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let effectiveIcon = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: group.iconSymbol,
            configured: resolvedConfig?.iconSymbol
        )
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let newWorkspacePlacement = resolvedConfig?.newWorkspacePlacement
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return memberWorkspaceIds.reduce(0) { partial, workspaceId in
                    partial + notificationStore.unreadCount(forTabId: workspaceId)
                }
            }
            return notificationStore.unreadCount(forTabId: group.anchorWorkspaceId)
        }()
        let anchorIndex = renderContext.tabIndexById[group.anchorWorkspaceId] ?? 0
        let shortcutDigit = WorkspaceShortcutMapper.digitForWorkspace(
            at: anchorIndex,
            workspaceCount: renderContext.workspaceCount
        )
        let modifierSymbol = renderContext.workspaceNumberShortcut.numberedDigitHintPrefix
        let showsHintForAnchor = modifierKeyMonitor.isModifierPressed
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate.topVisible(
            forTabId: group.anchorWorkspaceId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds
        )
        let onDragStart: () -> NSItemProvider = { [anchorId = group.anchorWorkspaceId] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag groupAnchor=\(anchorId.uuidString.prefix(5))")
            #endif
            dragState.beginDragging(tabId: anchorId)
            return SidebarTabDragPayload.provider(for: anchorId)
        }
        let tabDropDelegateFactory: (CGFloat) -> SidebarWorkspaceGroupHeaderDropDelegate = { [
            groupId = group.id,
            anchorId = group.anchorWorkspaceId,
            workspaceGroupIdByWorkspaceId = renderContext.workspaceGroupIdByWorkspaceId,
            selectedTabIds = $selectedTabIds,
            lastSidebarSelectionIndex = $lastSidebarSelectionIndex
        ] rowHeight in
            let reorderDelegate = SidebarTabDropDelegate(
                targetTabId: anchorId,
                tabManager: tabManager,
                workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId,
                dragState: dragState,
                selectedTabIds: selectedTabIds,
                lastSidebarSelectionIndex: lastSidebarSelectionIndex,
                targetRowHeight: rowHeight,
                dragAutoScrollController: dragAutoScrollController
            )
            return SidebarWorkspaceGroupHeaderDropDelegate(
                targetGroupId: groupId,
                targetAnchorWorkspaceId: anchorId,
                tabManager: tabManager,
                dragState: dragState,
                targetRowHeight: rowHeight,
                dragAutoScrollController: dragAutoScrollController,
                reorderDelegate: reorderDelegate
            )
        }

        let header = SidebarWorkspaceGroupHeaderView(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            memberCount: memberWorkspaceIds.count,
            anchorUnreadCount: anchorUnreadCount,
            shortcutDigit: shortcutDigit,
            shortcutModifierSymbol: modifierSymbol,
            showsShortcutHint: showsHintForAnchor,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            cwdContextMenuItems: cwdContextMenuItems,
            newWorkspacePlacement: newWorkspacePlacement,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == group.anchorWorkspaceId,
            isBeingDragged: dragState.draggedTabId == group.anchorWorkspaceId,
            topDropIndicatorVisible: topDropIndicatorVisible,
            onDragStart: onDragStart,
            tabDropDelegateFactory: tabDropDelegateFactory,
            onToggleCollapsed: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onFocusAnchor: { [weak tabManager, anchorId = group.anchorWorkspaceId, selectedTabIds = $selectedTabIds, lastSidebarSelectionIndex = $lastSidebarSelectionIndex] in
                guard let tabManager else { return }
                guard let anchorTab = tabManager.tabs.first(where: { $0.id == anchorId }) else { return }
                tabManager.selectWorkspace(anchorTab)
                if selectedTabIds.wrappedValue != [anchorId] {
                    selectedTabIds.wrappedValue = [anchorId]
                }
                if let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == anchorId }) {
                    lastSidebarSelectionIndex.wrappedValue = anchorIndex
                }
            },
            onTapPlus: { [weak tabManager, groupId = group.id, placement = newWorkspacePlacement] in
                guard let tabManager else { return }
                let resolved = placement ?? WorkspaceGroupNewWorkspacePlacementSettings.resolved()
                _ = tabManager.createWorkspaceInGroup(groupId: groupId, placement: resolved)
            },
            onRunResolvedItem: { [weak tabManager, groupId = group.id] item in
                guard let tabManager else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: groupId
                )
            },
            onRename: { [weak tabManager, groupId = group.id, currentName = group.name] in
                guard let tabManager else { return }
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: groupId,
                    currentName: currentName
                )
            },
            onTogglePinned: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            onUngroup: { [weak tabManager, groupId = group.id] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            onDelete: { [weak tabManager, groupId = group.id, groupName = group.name, memberCount = memberWorkspaceIds.count] in
                guard let tabManager else { return }
                let otherMemberCount = max(memberCount - 1, 0)
                guard confirmDeleteWorkspaceGroup(groupName: groupName, otherMemberCount: otherMemberCount) else { return }
                tabManager.deleteWorkspaceGroup(groupId: groupId)
            },
            onEditConfig: {
                SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
            },
            onOpenDocs: {
                SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs()
            }
        )
        .equatable()
        .id(group.anchorWorkspaceId)
        .accessibilityIdentifier("sidebarWorkspaceGroup.\(group.id.uuidString)")

        header
            .sidebarWorkspaceFrameAnchor(
                id: group.anchorWorkspaceId,
                isEnabled: shouldCollectWorkspaceDropTargets
            )
    }
}
