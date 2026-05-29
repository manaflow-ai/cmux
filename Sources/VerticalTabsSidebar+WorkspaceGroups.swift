import AppKit
import SwiftUI

extension VerticalTabsSidebar {
    @ViewBuilder
    func sidebarWorkspaceGroupHeader(
        group: WorkspaceGroup,
        memberCount: Int,
        renderContext: WorkspaceListRenderContext
    ) -> some View {
        let settings = renderContext.tabItemSettings
        let isAnchorActive = tabManager.selectedTabId == group.anchorWorkspaceId
        let anchorCwd = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let effectiveIcon = group.iconSymbol ?? resolvedConfig?.iconSymbol ?? "folder.fill"
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return tabManager.tabs.reduce(0) { partial, tab in
                    tab.groupId == group.id
                        ? partial + notificationStore.unreadCount(forTabId: tab.id)
                        : partial
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
        let sidebarReorderIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: group.anchorWorkspaceId
        )
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate.topVisible(
            forTabId: group.anchorWorkspaceId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds
        )
        let onDragStart: () -> NSItemProvider = { [anchorId = group.anchorWorkspaceId] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag groupAnchor=\(anchorId.uuidString.prefix(5))")
            #endif
            dragState.draggedTabId = anchorId
            dragState.dropIndicator = nil
            return SidebarTabDragPayload.provider(for: anchorId)
        }
        let tabDropDelegateFactory: (CGFloat) -> SidebarWorkspaceGroupHeaderDropDelegate = { [
            groupId = group.id,
            anchorId = group.anchorWorkspaceId,
            selectedTabIds = $selectedTabIds,
            lastSidebarSelectionIndex = $lastSidebarSelectionIndex
        ] rowHeight in
            let reorderDelegate = SidebarTabDropDelegate(
                targetTabId: anchorId,
                tabManager: tabManager,
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

        SidebarWorkspaceGroupHeaderView(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            memberCount: memberCount,
            anchorUnreadCount: anchorUnreadCount,
            shortcutDigit: shortcutDigit,
            shortcutModifierSymbol: modifierSymbol,
            showsShortcutHint: showsHintForAnchor,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            cwdContextMenuItems: cwdContextMenuItems,
            rowSpacing: tabRowSpacing,
            isFirstRow: sidebarReorderIds.first == group.anchorWorkspaceId,
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
            onTapPlus: { [weak tabManager, groupId = group.id, placement = resolvedConfig?.newWorkspacePlacement] in
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
            onDelete: { [weak tabManager, groupId = group.id, groupName = group.name] in
                guard let tabManager else { return }
                let otherMemberCount = max(tabManager.tabs.filter { $0.groupId == groupId }.count - 1, 0)
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
        .id(group.anchorWorkspaceId)
        .accessibilityIdentifier("sidebarWorkspaceGroup.\(group.id.uuidString)")
        .preference(key: SidebarWorkspaceRowIdsPreferenceKey.self, value: Set([group.anchorWorkspaceId]))
        .anchorPreference(key: SidebarWorkspaceRowFramePreferenceKey.self, value: .bounds) { [anchorId = group.anchorWorkspaceId] anchor in
            [anchorId: anchor]
        }
    }
}
