import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Resolves native sidebar interactions against live window state.
///
/// Cells retain stable ids and call this coordinator only in response to a
/// user event. Deferred actions never capture a stale workspace array.
@MainActor
final class SidebarAppKitInteractionCoordinator {
    struct StateAccess {
        var selectedWorkspaceIds: () -> Set<UUID>
        var setSelectedWorkspaceIds: (Set<UUID>) -> Void
        var lastSelectionIndex: () -> Int?
        var setLastSelectionIndex: (Int?) -> Void
        var selectTabsPage: () -> Void
        var showsAgentActivity: () -> Bool
    }

    private let tabManager: TabManager
    private let projectionSource: SidebarAppKitProjectionSource
    private let notificationStore: TerminalNotificationStore
    private var state: StateAccess

    init(
        tabManager: TabManager,
        projectionSource: SidebarAppKitProjectionSource,
        notificationStore: TerminalNotificationStore = .shared,
        state: StateAccess
    ) {
        self.tabManager = tabManager
        self.projectionSource = projectionSource
        self.notificationStore = notificationStore
        self.state = state
    }

    func updateStateAccess(_ state: StateAccess) {
        self.state = state
    }

    func activateWorkspace(_ workspaceId: UUID, modifiers: NSEvent.ModifierFlags) {
        guard let workspace = projectionSource.workspaceById[workspaceId],
              let clickedIndex = projectionSource.workspaceIndexById[workspaceId] else {
            return
        }
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasFocused = tabManager.selectedTabId == workspaceId
        var selectedIds = state.selectedWorkspaceIds()

        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
                existingAnchorIndex: state.lastSelectionIndex(),
                selectedWorkspaceIds: selectedIds,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: tabManager.tabs.map(\.id)
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, clickedIndex)
            let upper = max(anchorIndex, clickedIndex)
            let collapsedGroupIds = Set(
                projectionSource.groupById.values.filter(\.isCollapsed).map(\.id)
            )
            let anchorIdsByGroup = Dictionary(
                uniqueKeysWithValues: projectionSource.groupById.values.map {
                    ($0.id, $0.anchorWorkspaceId)
                }
            )
            let rangeIds = tabManager.tabs[lower...upper].compactMap { candidate -> UUID? in
                if let groupId = candidate.groupId,
                   collapsedGroupIds.contains(groupId),
                   anchorIdsByGroup[groupId] != candidate.id {
                    return nil
                }
                return candidate.id
            }
            if isCommand {
                selectedIds.formUnion(rangeIds)
            } else {
                selectedIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedIds.contains(workspaceId) {
                selectedIds.remove(workspaceId)
            } else {
                selectedIds.insert(workspaceId)
            }
        } else {
            selectedIds = [workspaceId]
        }

        state.setSelectedWorkspaceIds(selectedIds)
        state.setLastSelectionIndex(
            SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
                isShiftClick: isShift,
                resolvedShiftAnchorIndex: shiftAnchorIndex,
                clickedIndex: clickedIndex
            )
        )
        tabManager.selectTab(workspace)
        if wasFocused, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: workspaceId,
                surfaceId: tabManager.focusedSurfaceId(for: workspaceId)
            )
        }
        state.selectTabsPage()
        projectionSource.updateExternalState(
            selectedWorkspaceIds: selectedIds,
            showsAgentActivity: state.showsAgentActivity()
        )
    }

    func focusGroupAnchor(_ groupId: UUID) {
        guard let group = projectionSource.groupById[groupId],
              let workspace = projectionSource.workspaceById[group.anchorWorkspaceId] else {
            return
        }
        tabManager.selectWorkspace(workspace)
        state.setSelectedWorkspaceIds([workspace.id])
        state.setLastSelectionIndex(projectionSource.workspaceIndexById[workspace.id])
        state.selectTabsPage()
        projectionSource.updateExternalState(
            selectedWorkspaceIds: [workspace.id],
            showsAgentActivity: state.showsAgentActivity()
        )
    }

    func toggleGroupCollapsed(_ groupId: UUID) {
        tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)
    }

    func addWorkspace(toGroup groupId: UUID) {
        let placement = projectionSource.groupSnapshot(groupId: groupId)?.newWorkspacePlacement
            ?? UserDefaultsSettingsClient(defaults: .standard)
                .value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
        _ = tabManager.createWorkspaceInGroup(groupId: groupId, placement: placement)
    }

    func addWorkspaceAtEnd() {
        if tabManager.selectedTab?.isRemoteTmuxMirror == true {
            _ = AppDelegate.shared?.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "sidebar.appKit.emptyArea.remoteTmux"
            )
        } else {
            tabManager.addWorkspace(placementOverride: .end)
        }
        let selectedId = tabManager.selectedTabId
        state.setSelectedWorkspaceIds(selectedId.map { [$0] } ?? [])
        state.setLastSelectionIndex(
            selectedId.flatMap { id in tabManager.tabs.firstIndex { $0.id == id } }
        )
        state.selectTabsPage()
    }

    func renameWorkspace(_ workspaceId: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabManager.setCustomTitle(tabId: workspaceId, title: trimmed)
    }

    func clearWorkspaceTitle(_ workspaceId: UUID) {
        tabManager.clearCustomTitle(tabId: workspaceId)
    }

    func closeWorkspace(_ workspaceId: UUID) {
        guard let workspace = projectionSource.workspaceById[workspaceId] else { return }
        tabManager.closeWorkspaceFromTabCloseButton(workspace)
        reconcileSelectionAfterMutation()
    }

    func closeWorkspaceFromMiddleClick(_ workspaceId: UUID) {
        guard let workspace = projectionSource.workspaceById[workspaceId] else { return }
        tabManager.closeWorkspaceWithConfirmation(workspace)
        reconcileSelectionAfterMutation()
    }

    func reconnectRemoteWorkspace(_ workspaceId: UUID) {
        guard let workspace = projectionSource.workspaceById[workspaceId],
              workspace.isRemoteWorkspace,
              !workspace.isManagedCloudVMWorkspace else {
            return
        }
        workspace.reconnectRemoteConnection()
    }

    func copyRemoteError(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        WorkspaceSurfaceIdentifierClipboardText.copy(text)
    }

    func moveWorkspace(_ workspaceId: UUID, by delta: Int) {
        guard tabManager.reorderWorkspace(tabId: workspaceId, by: delta) else { return }
        state.setSelectedWorkspaceIds([workspaceId])
        state.setLastSelectionIndex(tabManager.tabs.firstIndex { $0.id == workspaceId })
        if let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
            tabManager.selectTab(workspace)
        }
        state.selectTabsPage()
    }

    func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let requestedIds = Set(workspaceIds)
        let orderedIds = tabManager.tabs.compactMap {
            requestedIds.contains($0.id) ? $0.id : nil
        }
        guard !orderedIds.isEmpty else { return }

        var movedIds: [UUID] = []
        movedIds.reserveCapacity(orderedIds.count)
        for workspaceId in orderedIds {
            if app.moveWorkspaceToWindow(
                workspaceId: workspaceId,
                windowId: windowId,
                focus: false
            ) {
                movedIds.append(workspaceId)
            }
        }
        guard let focusId = movedIds.last else { return }
        _ = app.moveWorkspaceToWindow(
            workspaceId: focusId,
            windowId: windowId,
            focus: true
        )
        reconcileSelectionAfterMutation()
    }

    func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let requestedIds = Set(workspaceIds)
        let orderedIds = tabManager.tabs.compactMap {
            requestedIds.contains($0.id) ? $0.id : nil
        }
        guard let firstId = orderedIds.first,
              let newWindowId = app.moveWorkspaceToNewWindow(
                workspaceId: firstId,
                focus: false
              ) else {
            return
        }

        var movedIds = [firstId]
        movedIds.reserveCapacity(orderedIds.count)
        for workspaceId in orderedIds.dropFirst() {
            if app.moveWorkspaceToWindow(
                workspaceId: workspaceId,
                windowId: newWindowId,
                focus: false
            ) {
                movedIds.append(workspaceId)
            }
        }
        if let focusId = movedIds.last {
            _ = app.moveWorkspaceToWindow(
                workspaceId: focusId,
                windowId: newWindowId,
                focus: true
            )
        }
        reconcileSelectionAfterMutation()
    }

    func markWorkspaceRead(_ workspaceId: UUID) {
        guard notificationStore.canMarkWorkspaceRead(forTabIds: [workspaceId]) else { return }
        notificationStore.markRead(forTabId: workspaceId)
    }

    func markWorkspaceUnread(_ workspaceId: UUID) {
        guard notificationStore.canMarkWorkspaceUnread(forTabIds: [workspaceId]) else { return }
        notificationStore.markUnread(forTabId: workspaceId)
    }

    func openURL(_ url: URL, fromWorkspace workspaceId: UUID) {
        let settings = SidebarTabItemSettingsSnapshot()
        openURL(
            url,
            fromWorkspace: workspaceId,
            prefersCmuxBrowser: settings.openPullRequestLinksInCmuxBrowser
        )
    }

    func openMetadataURL(_ url: URL, fromWorkspace workspaceId: UUID) {
        openURL(url, fromWorkspace: workspaceId, prefersCmuxBrowser: false)
    }

    func openPort(_ port: Int, fromWorkspace workspaceId: UUID) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        let settings = SidebarTabItemSettingsSnapshot()
        openURL(
            url,
            fromWorkspace: workspaceId,
            prefersCmuxBrowser: settings.openPortLinksInCmuxBrowser
        )
    }

    private func openURL(
        _ url: URL,
        fromWorkspace workspaceId: UUID,
        prefersCmuxBrowser: Bool
    ) {
        guard projectionSource.workspaceById[workspaceId] != nil else { return }
        activateWorkspace(workspaceId, modifiers: NSEvent.modifierFlags)
        if prefersCmuxBrowser,
           tabManager.openBrowser(
               inWorkspace: workspaceId,
               url: url,
               preferSplitRight: true,
               insertAtEnd: true
           ) != nil {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func dragItemProvider(for workspaceId: UUID) -> NSItemProvider {
        SidebarTabDragPayload(tabId: workspaceId).provider()
    }

    /// Reconciles the sidebar's multi-selection and shift-click anchor after an
    /// action mutates ordering or removes workspaces. Context-menu actions use
    /// the same path as native row buttons so no entrypoint leaves stale ids or
    /// an anchor index pointing at the previous order.
    func reconcileSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map(\.id))
        var selectedIds = state.selectedWorkspaceIds().intersection(existingIds)
        if selectedIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedIds = [selectedId]
        }
        state.setSelectedWorkspaceIds(selectedIds)
        state.setLastSelectionIndex(
            tabManager.selectedTabId.flatMap { selectedId in
                tabManager.tabs.firstIndex { $0.id == selectedId }
            }
        )
        projectionSource.updateExternalState(
            selectedWorkspaceIds: selectedIds,
            showsAgentActivity: state.showsAgentActivity()
        )
    }
}
