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
        .onDrag { [groupId = group.id] in
            SidebarWorkspaceGroupDragPayload.provider(for: groupId)
        }
        .onDrop(
            of: SidebarWorkspaceGroupDragPayload.dropContentTypes
                + SidebarTabDragPayload.dropContentTypes,
            isTargeted: nil
        ) { [dragState, dragAutoScrollController] providers in
            SidebarWorkspaceGroupDragPayload.loadGroupId(from: providers) { [weak tabManager, targetGroupId = group.id] draggedId in
                guard let draggedId, draggedId != targetGroupId, let tabManager else { return }
                guard let targetIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == targetGroupId }) else { return }
                tabManager.moveWorkspaceGroup(groupId: draggedId, toIndex: targetIndex)
            }
            SidebarTabDragPayload.loadTabId(from: providers) { [weak tabManager, targetGroupId = group.id] draggedTabId in
                guard let draggedTabId, let tabManager else { return }
                tabManager.addWorkspaceToGroup(workspaceId: draggedTabId, groupId: targetGroupId)
            }
            dragState.draggedTabId = nil
            dragState.dropIndicator = nil
            dragAutoScrollController.stop()
            return true
        }
    }
}
