import CmuxMobileShellModel

/// Resolves notification destinations from one immutable workspace snapshot.
struct NotificationFeedWorkspaceTargetIndex: Sendable {
    private var workspacesByRemoteID: [NotificationFeedWorkspaceLookupKey: NotificationFeedWorkspaceTarget] = [:]
    private var workspacesBySurfaceID: [NotificationFeedWorkspaceLookupKey: NotificationFeedWorkspaceTarget] = [:]

    init(workspaces: [MobileWorkspacePreview]) {
        for workspace in workspaces {
            guard let macDeviceID = workspace.macDeviceID, !macDeviceID.isEmpty else {
                continue
            }
            let workspaceKey = NotificationFeedWorkspaceLookupKey(
                macDeviceID: macDeviceID,
                targetID: workspace.rpcWorkspaceID.rawValue
            )
            workspacesByRemoteID[workspaceKey, default: NotificationFeedWorkspaceTarget()].insert(
                rowID: workspace.id,
                macDeviceID: macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            for terminal in workspace.terminals {
                let surfaceKey = NotificationFeedWorkspaceLookupKey(
                    macDeviceID: macDeviceID,
                    targetID: terminal.id.rawValue
                )
                workspacesBySurfaceID[surfaceKey, default: NotificationFeedWorkspaceTarget()].insert(
                    rowID: workspace.id,
                    macDeviceID: macDeviceID,
                    instanceTag: workspace.macInstanceTag
                )
            }
        }
    }

    func workspaceID(
        for item: MobileNotificationFeedItem
    ) -> MobileWorkspacePreview.ID? {
        let targetID: String
        let targets: [NotificationFeedWorkspaceLookupKey: NotificationFeedWorkspaceTarget]
        if item.retargetsToLiveSurfaceOwner, let surfaceID = item.remoteSurfaceID {
            targetID = surfaceID
            targets = workspacesBySurfaceID
        } else {
            targetID = item.remoteWorkspaceID
            targets = workspacesByRemoteID
        }
        return targets[
            NotificationFeedWorkspaceLookupKey(macDeviceID: item.macDeviceID, targetID: targetID)
        ]?.rowID(instanceTag: item.macInstanceTag)
    }
}
