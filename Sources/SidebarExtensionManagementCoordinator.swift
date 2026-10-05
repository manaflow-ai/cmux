import AppKit
@_spi(CmuxHostTransport) import CmuxExtensionKit
import Foundation

/// Dispatches extension management requests through CMUX's native mutation paths.
/// Modal callbacks are injectable so cancellation and target loss can be tested.
@MainActor
struct SidebarExtensionManagementCoordinator {
    enum RenameTarget {
        case workspace
        case surface
        case group
    }

    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    var authorization = SidebarActionAuthorization.current ?? SidebarActionAuthorization(isCurrent: { true })
    var requestTitle: (@MainActor (RenameTarget, String, UUID?) -> String?)?
    var confirmGroupDeletion: @MainActor (String, Int) -> Bool = { name, count in
        confirmDeleteWorkspaceGroup(groupName: name, memberCount: count)
    }

    func perform(_ action: CmuxSidebarAction) -> CmuxSidebarActionResult? {
        guard authorization.isValid else { return .cancelled }
        if let result = SidebarExtensionAgentSessionBindingCoordinator(tabManager: tabManager).perform(action) { return result }
        if let result = SidebarExtensionWorkspaceContextCoordinator(tabManager: tabManager).perform(action) { return result }
        switch action {
        case .renameWorkspace(let id, let title):
            guard let workspace = workspace(id) else { return missingWorkspace }
            guard let proposed = title ?? promptTitle(.workspace, current: workspace.title, workspaceID: id) else { return .cancelled }
            guard authorization.isValid else { return .cancelled }
            guard self.workspace(id) != nil else { return missingWorkspace }
            let title = normalized(proposed)
            let applied = tabManager.setCustomTitle(tabId: id, title: title)
            return applied || self.workspace(id)?.customTitle == title ? .accepted : unavailable
        case .renameSurface(let id, let surfaceID, let title):
            guard let workspace = workspace(id), let panel = workspace.panels[surfaceID] else { return missingSurface }
            let current = workspace.panelTitle(panelId: surfaceID) ?? panel.displayTitle
            guard let proposed = title ?? promptTitle(.surface, current: current, workspaceID: id) else { return .cancelled }
            guard authorization.isValid else { return .cancelled }
            guard let live = self.workspace(id), live.panels[surfaceID] != nil else { return missingSurface }
            let title = normalized(proposed)
            let applied = live.setPanelCustomTitle(panelId: surfaceID, title: title)
            return applied || live.panelCustomTitles[surfaceID] == title ? .accepted : unavailable
        case .renameWorkspaceGroup(let id, let title):
            guard let group = tabManager.workspaceGroups.first(where: { $0.id == id }) else { return missingGroup }
            guard let proposed = title ?? promptTitle(.group, current: group.name, workspaceID: nil) else { return .cancelled }
            guard authorization.isValid else { return .cancelled }
            guard let name = normalized(proposed) else { return unavailable }
            guard tabManager.workspaceGroups.contains(where: { $0.id == id }) else { return missingGroup }
            tabManager.renameWorkspaceGroup(groupId: id, name: name)
            return .accepted
        case .createWorkspaceGroup(let name, let ids):
            guard Set(ids).count == ids.count,
                  ids.allSatisfy({ workspace($0) != nil }) else { return unavailable }
            guard let id = tabManager.createWorkspaceGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), childWorkspaceIds: ids, selectAnchor: false, collapseSidebarSelection: false) else { return unavailable }
            return CmuxSidebarActionResult(accepted: true, message: id.uuidString)
        case .setWorkspacePinned(let id, let isPinned):
            guard let workspace = workspace(id) else { return missingWorkspace }
            tabManager.setPinned(workspace, pinned: isPinned)
            return .accepted
        case .setWorkspaceImportance(let id, let importance):
            guard tabManager.setWorkspaceImportance(workspaceId: id, importance: Workspace.Importance(rawValue: importance.rawValue) ?? .none) else { return missingWorkspace }
            return .accepted
        case .setWorkspaceGroupCollapsed(let id, let isCollapsed):
            guard tabManager.workspaceGroups.contains(where: { $0.id == id }) else { return missingGroup }
            tabManager.setWorkspaceGroupCollapsed(groupId: id, isCollapsed: isCollapsed)
            return .accepted
        case .moveWorkspaceToGroup(let id, let groupID):
            guard workspace(id) != nil else { return missingWorkspace }
            if let groupID {
                guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else { return missingGroup }
                tabManager.addWorkspaceToGroup(workspaceId: id, groupId: groupID)
            } else {
                tabManager.removeWorkspaceFromGroup(workspaceId: id)
            }
            return .accepted
        case .ungroupWorkspaceGroup(let id):
            guard tabManager.workspaceGroups.contains(where: { $0.id == id }) else { return missingGroup }
            tabManager.ungroupWorkspaceGroup(groupId: id)
            return .accepted
        case .deleteWorkspaceGroup(let id):
            guard let group = tabManager.workspaceGroups.first(where: { $0.id == id }),
                  let captured = tabManager.workspaceGrouping.deletionConfirmation(groupId: id, fallbackGroupName: group.name, fallbackAnchorWorkspaceId: group.anchorWorkspaceId) else { return missingGroup }
            guard confirmGroupDeletion(captured.groupName, captured.containedWorkspaceCount) else { return .cancelled }
            guard authorization.isValid else { return .cancelled }
            // Never recapture membership after the alert. New members are not
            // covered by the user's confirmation and must survive.
            guard tabManager.workspaceGroups.contains(where: { $0.id == id }) else { return missingGroup }
            tabManager.workspaceGrouping.deleteWorkspaceGroup(confirmed: captured)
            return .accepted
        case .markWorkspaceRead(let id):
            guard workspace(id) != nil else { return missingWorkspace }
            notificationStore.markRead(forTabId: id)
            return .accepted
        case .markWorkspaceUnread(let id):
            guard workspace(id) != nil else { return missingWorkspace }
            notificationStore.markUnread(forTabId: id)
            return .accepted
        case .clearWorkspaceNotifications(let id):
            guard workspace(id) != nil else { return missingWorkspace }
            notificationStore.clearLatestNotification(forTabId: id)
            return .accepted
        case .setWorkspaceMuted(let id, let isMuted):
            guard let workspace = workspace(id) else { return missingWorkspace }
            notificationStore.setWorkspaceNotificationsMuted(isMuted, forTabIds: [id])
            return workspace.isMuted == isMuted ? .accepted : unavailable
        case .setWorkspaceDescription(let id, let description):
            guard workspace(id) != nil else { return missingWorkspace }
            tabManager.setCustomDescription(tabId: id, description: description)
            return .accepted
        case .setWorkspaceColor(let id, let color):
            guard workspace(id) != nil else { return missingWorkspace }
            if let color {
                guard let value = WorkspaceTabColorSettings.normalizedHex(color) else { return unavailable }
                tabManager.setTabColor(tabId: id, color: value)
            } else {
                tabManager.setTabColor(tabId: id, color: nil)
            }
            return .accepted
        case .moveWorkspace(let id, let beforeID):
            guard workspace(id) != nil else { return missingWorkspace }
            if let beforeID {
                guard workspace(beforeID) != nil, id != beforeID else { return unavailable }
                return tabManager.reorderWorkspace(tabId: id, before: beforeID) ? .accepted : unavailable
            }
            return tabManager.reorderWorkspace(tabId: id, toIndex: max(0, tabManager.tabs.count - 1)) ? .accepted : unavailable
        default:
            return nil
        }
    }

    private func workspace(_ id: UUID) -> Workspace? {
        tabManager.tabs.first(where: { $0.id == id })
    }

    private func normalized(_ value: String) -> String? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private var missingWorkspace: CmuxSidebarActionResult {
        .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
    }
    private var missingSurface: CmuxSidebarActionResult {
        .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
    }
    private var missingGroup: CmuxSidebarActionResult {
        .rejected(String(localized: "sidebar.extensions.action.groupNotFound", defaultValue: "Group not found"))
    }
    private var unavailable: CmuxSidebarActionResult {
        .rejected(String(localized: "sidebar.extensions.action.unavailable", defaultValue: "Action is unavailable"))
    }

    private func promptTitle(_ target: RenameTarget, current: String, workspaceID: UUID?) -> String? {
        if let requestTitle { return requestTitle(target, current, workspaceID) }
        let alert = NSAlert()
        let input = NSTextField(string: current)
        switch target {
        case .workspace:
            alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
            alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
            input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        case .surface:
            alert.messageText = String(localized: "alert.renameTab.title", defaultValue: "Rename Tab")
            alert.informativeText = String(localized: "alert.renameTab.message", defaultValue: "Enter a custom name for this tab.")
            input.placeholderString = String(localized: "alert.renameTab.placeholder", defaultValue: "Tab name")
        case .group:
            alert.messageText = String(localized: "workspaceGroup.rename.title", defaultValue: "Rename Group")
            alert.informativeText = String(localized: "workspaceGroup.rename.message", defaultValue: "Enter a new name for this group.")
            input.placeholderString = String(localized: "workspaceGroup.rename.placeholder", defaultValue: "Group name")
        }
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameTab.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let window = alert.window
        window.initialFirstResponder = input
        let response = alert.runCmuxModal(presentingWindow: workspaceID.flatMap { AppDelegate.shared?.mainWindowContainingWorkspace($0) }) { _ in
            window.makeFirstResponder(input)
            input.selectText(nil)
        }
        return response == .alertFirstButtonReturn ? input.stringValue : nil
    }
}
