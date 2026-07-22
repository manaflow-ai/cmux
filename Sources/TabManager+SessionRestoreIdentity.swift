import Foundation

extension TabManager {
    typealias SessionRestoreNotificationReplacement = (workspace: Workspace, panelIdMap: [UUID: UUID])

    func liveStableIdentitySet() -> Set<UUID> {
        var identities: Set<UUID> = []
        for workspace in tabs {
            identities.insert(workspace.stableId)
            for panel in workspace.panels.values {
                identities.insert(panel.stableSurfaceId)
            }
        }
        for dock in DockSplitStore.liveStores {
            for panel in dock.panels.values {
                identities.insert(panel.stableSurfaceId)
            }
        }
        return identities
    }

    func releaseRestoredAwayWorkspaces(
        _ previousWorkspaces: [Workspace],
        originalWorkspaceIds: [UUID?],
        replacements: [Workspace],
        panelIdMaps: [[UUID: UUID]]
    ) {
        precondition(originalWorkspaceIds.count == panelIdMaps.count)
        precondition(replacements.count >= originalWorkspaceIds.count)
        var replacementByOriginalId: [UUID: SessionRestoreNotificationReplacement] = [:]
        for (originalId, replacement) in zip(originalWorkspaceIds, zip(replacements, panelIdMaps)) {
            guard let originalId, replacementByOriginalId[originalId] == nil else { continue }
            replacementByOriginalId[originalId] = (replacement.0, replacement.1)
        }

        for workspace in previousWorkspaces {
            releaseRestoredAwayWorkspace(
                workspace,
                replacement: replacementByOriginalId[workspace.id]
            )
        }
    }

    private func releaseRestoredAwayWorkspace(
        _ workspace: Workspace,
        replacement: SessionRestoreNotificationReplacement?
    ) {
        if let replacement {
            AppDelegate.shared?.notificationStore?.transferSessionNotifications(
                fromTabId: workspace.id,
                toTabId: replacement.workspace.id,
                panelIdMap: replacement.panelIdMap
            )
            workspace.teardownAllPanels(clearSurfaceNotifications: false)
        } else {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }
}
