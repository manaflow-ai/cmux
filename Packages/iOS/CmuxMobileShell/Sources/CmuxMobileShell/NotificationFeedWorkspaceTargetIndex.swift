import CmuxMobileShellModel

/// Resolves notification destinations from one immutable workspace snapshot.
struct NotificationFeedWorkspaceTargetIndex: Sendable {
    private struct LookupKey: Hashable, Sendable {
        let macDeviceID: String
        let targetID: String
    }

    private struct Target: Sendable {
        var firstRowID: MobileWorkspacePreview.ID?
        var exactRowsByInstanceTag: [String: MobileWorkspacePreview.ID] = [:]
        var owners: Set<MacPairingKey> = []
        var ownerDevices: Set<String> = []

        mutating func insert(
            rowID: MobileWorkspacePreview.ID,
            macDeviceID: String,
            instanceTag: String?
        ) {
            if firstRowID == nil {
                firstRowID = rowID
            }
            if let instanceTag, !instanceTag.isEmpty,
               exactRowsByInstanceTag[instanceTag] == nil {
                exactRowsByInstanceTag[instanceTag] = rowID
            }
            let owner = MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
            owners.insert(owner)
            ownerDevices.insert(owner.canonicalMacDeviceID)
        }

        func rowID(instanceTag: String?) -> MobileWorkspacePreview.ID? {
            if let instanceTag, !instanceTag.isEmpty {
                return exactRowsByInstanceTag[instanceTag]
            }
            guard owners.count <= ownerDevices.count else { return nil }
            return firstRowID
        }
    }

    private var workspacesByRemoteID: [LookupKey: Target] = [:]
    private var workspacesBySurfaceID: [LookupKey: Target] = [:]

    init(workspaces: [MobileWorkspacePreview]) {
        for workspace in workspaces {
            guard let macDeviceID = workspace.macDeviceID, !macDeviceID.isEmpty else {
                continue
            }
            let workspaceKey = LookupKey(
                macDeviceID: macDeviceID,
                targetID: workspace.rpcWorkspaceID.rawValue
            )
            workspacesByRemoteID[workspaceKey, default: Target()].insert(
                rowID: workspace.id,
                macDeviceID: macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            for terminal in workspace.terminals {
                let surfaceKey = LookupKey(
                    macDeviceID: macDeviceID,
                    targetID: terminal.id.rawValue
                )
                workspacesBySurfaceID[surfaceKey, default: Target()].insert(
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
        let targets: [LookupKey: Target]
        if item.retargetsToLiveSurfaceOwner, let surfaceID = item.remoteSurfaceID {
            targetID = surfaceID
            targets = workspacesBySurfaceID
        } else {
            targetID = item.remoteWorkspaceID
            targets = workspacesByRemoteID
        }
        return targets[
            LookupKey(macDeviceID: item.macDeviceID, targetID: targetID)
        ]?.rowID(instanceTag: item.macInstanceTag)
    }
}
