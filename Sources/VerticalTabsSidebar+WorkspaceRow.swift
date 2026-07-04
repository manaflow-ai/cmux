import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import SwiftUI

extension VerticalTabsSidebar {
    @ViewBuilder
    func workspaceRow(
        _ tab: Workspace,
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let index = renderContext.tabIndexById[tab.id] ?? 0
        let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
        let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedContextTargetIds
            : [tab.id]
        let remoteContextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedRemoteContextMenuWorkspaceIds
            : (tab.isRemoteWorkspace ? [tab.id] : [])
        let allRemoteContextMenuTargetsConnecting = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsConnecting
            : (
                tab.isRemoteWorkspace &&
                    (tab.remoteConnectionState == .connecting || tab.remoteConnectionState == .reconnecting)
            )
        let allRemoteContextMenuTargetsDisconnected = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsDisconnected
            : (tab.isRemoteWorkspace && tab.remoteConnectionState == .disconnected)
        let contextMenuPinTarget = WorkspaceActionDispatcher.Target(
            workspaceIds: contextMenuWorkspaceIds,
            anchorWorkspaceId: tab.id
        )
        let contextMenuPinState = WorkspaceActionDispatcher.pinState(
            in: renderContext.pinResolutionContext,
            target: contextMenuPinTarget
        )
        let liveUnreadCount = sidebarUnread.unreadCount(forWorkspaceId: tab.id)
        let liveLatestNotificationText: String? = showsSidebarNotificationMessage
            ? sidebarUnread.latestNotificationText(forWorkspaceId: tab.id)
            : nil
        let liveShowsModifierShortcutHints = showModifierHoldHints && modifierKeyMonitor.isModifierPressed
        let resolvedShowsModifierShortcutHints = SidebarShortcutHintFreezePolicy().resolved(
            live: liveShowsModifierShortcutHints,
            currentTabId: tab.id,
            frozenTabId: frozenShortcutHintsTabId,
            frozenValue: frozenShortcutHintsValue
        )
        let onContextMenuAppear: () -> Void = { [tabId = tab.id, snapshot = resolvedShowsModifierShortcutHints] in
            frozenShortcutHintsTabId = tabId
            frozenShortcutHintsValue = snapshot
        }
        let onContextMenuDisappear: () -> Void = { [tabId = tab.id] in
            if frozenShortcutHintsTabId == tabId {
                frozenShortcutHintsTabId = nil
            }
        }

        // Per-row drag/drop snapshots. Reading `dragState` here in the parent
        // is intentional: the parent owns the @Observable store, and these
        // value snapshots are what get passed to the row. The row's
        // Equatable conformance ignores closures, so rows whose snapshot is
        // unchanged skip re-render when drag state moves.
        let isBeingDragged = dragState.draggedTabId == tab.id
        let sidebarReorderIds = renderContext.sidebarReorderIds
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        let onDragStart: () -> NSItemProvider = { [tabId = tab.id] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag tab=\(tabId.uuidString.prefix(5))")
            #endif
            dragState.beginDragging(tabId: tabId)
            return SidebarTabDragPayload.provider(for: tabId)
        }
        let bonsplitSourceWorkspaceId: @MainActor (UUID) -> UUID? = { tabId in
            guard let app = AppDelegate.shared else { return nil }
            return app.locateBonsplitSurface(tabId: tabId)?.workspaceId
        }
        let moveBonsplitTabToWorkspace: @MainActor (BonsplitTabDragPayload.Transfer, UUID) -> Bool = { transfer, workspaceId in
            guard let app = AppDelegate.shared else { return false }
            return app.moveBonsplitTab(
                tabId: transfer.tab.id,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        }
        let syncSidebarSelectionAfterBonsplitDrop: @MainActor () -> Void = {
            if let selectedId = tabManager.selectedTabId {
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            } else {
                lastSidebarSelectionIndex = nil
            }
        }
        let workspaceIsUnread = liveUnreadCount > 0
        let row = SidebarSwipeableRow(
            workspaceId: tab.id,
            isUnread: workspaceIsUnread,
            isSelected: usesSelectedContextMenuTargets,
            onToggleReadState: { [notificationStore, tabId = tab.id, workspaceIsUnread] in
                if workspaceIsUnread {
                    notificationStore.markRead(forTabId: tabId)
                } else {
                    notificationStore.markUnread(forTabId: tabId)
                }
            },
            onDelete: { [tabManager, tab] in
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        ) {
            TabItemView(
                tabManager: tabManager,
                notificationStore: notificationStore,
                tab: tab,
                index: index,
                workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                    at: index,
                    workspaceCount: renderContext.workspaceCount
                ),
                workspaceShortcutModifierSymbol: renderContext.workspaceNumberShortcut.numberedDigitHintPrefix,
                canCloseWorkspace: renderContext.canCloseWorkspace,
                accessibilityWorkspaceCount: renderContext.workspaceCount,
                unreadCount: liveUnreadCount,
                latestNotificationText: liveLatestNotificationText,
                rowSpacing: tabRowSpacing,
                setSelectionToTabs: { selection = .tabs },
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                showsModifierShortcutHints: resolvedShowsModifierShortcutHints,
                dragAutoScrollController: dragAutoScrollController,
                isBeingDragged: isBeingDragged,
                topDropIndicatorVisible: topDropIndicatorVisible,
                bottomDropIndicatorVisible: bottomDropIndicatorVisible,
                isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropTargetCollectionActive,
                bonsplitSourceWorkspaceId: bonsplitSourceWorkspaceId,
                moveBonsplitTabToWorkspace: moveBonsplitTabToWorkspace,
                syncSidebarSelectionAfterBonsplitDrop: syncSidebarSelectionAfterBonsplitDrop,
                onDragStart: onDragStart,
                contextMenuWorkspaceIds: contextMenuWorkspaceIds,
                remoteContextMenuWorkspaceIds: remoteContextMenuWorkspaceIds,
                allRemoteContextMenuTargetsConnecting: allRemoteContextMenuTargetsConnecting,
                allRemoteContextMenuTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
                contextMenuPinState: contextMenuPinState,
                workspaceGroupMenuSnapshot: renderContext.workspaceGroupMenuSnapshot,
                settings: renderContext.tabItemSettings,
                onContextMenuAppear: onContextMenuAppear,
                onContextMenuDisappear: onContextMenuDisappear
            )
            .equatable()
            .id(tab.id)
            .accessibilityIdentifier("sidebarWorkspace.\(tab.id.uuidString)")
        }

        row
            .sidebarWorkspaceFrameAnchor(id: tab.id, isEnabled: shouldCollectWorkspaceDropTargets)
            .padding(.leading, tab.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
