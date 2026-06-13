import CmuxMobileRPC
import CmuxMobileShellModel

extension MobileShellComposite {
    func applyMergedRemoteWorkspaces(
        _ remoteWorkspaces: [MobileWorkspacePreview],
        replacingWindowSlices: Bool
    ) -> Set<MobileWorkspacePreview.ID> {
        guard replacingWindowSlices else {
            workspaces = mergeRemoteWorkspacesByID(remoteWorkspaces)
            return []
        }
        let windowIDs = Set(remoteWorkspaces.compactMap(\.windowID))
        let replacedWorkspaceIDs = Set(workspaces.filter { workspace in
            workspace.windowID.map { windowIDs.contains($0) } ?? false
        }.map(\.id))
        workspaces = mergeRemoteWorkspacesReplacingWindowSlices(remoteWorkspaces)
        return replacedWorkspaceIDs
    }

    func mergeRemoteWorkspacesByID(
        _ remoteWorkspaces: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        var mergedWorkspaces = workspaces
        for remoteWorkspace in remoteWorkspaces {
            if let existingIndex = mergedWorkspaces.firstIndex(where: { $0.id == remoteWorkspace.id }) {
                mergedWorkspaces[existingIndex] = remoteWorkspace
            } else {
                mergedWorkspaces.append(remoteWorkspace)
            }
        }
        return mergedWorkspaces
    }

    func mergeRemoteWorkspacesReplacingWindowSlices(
        _ remoteWorkspaces: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        var windowOrder: [String] = []
        var remoteByWindowID: [String: [MobileWorkspacePreview]] = [:]
        var remoteWithoutWindowID: [MobileWorkspacePreview] = []
        for remoteWorkspace in remoteWorkspaces {
            guard let windowID = remoteWorkspace.windowID else {
                remoteWithoutWindowID.append(remoteWorkspace)
                continue
            }
            if remoteByWindowID[windowID] == nil {
                windowOrder.append(windowID)
                remoteByWindowID[windowID] = []
            }
            remoteByWindowID[windowID]?.append(remoteWorkspace)
        }
        guard !remoteByWindowID.isEmpty else {
            return mergeRemoteWorkspacesByID(remoteWorkspaces)
        }

        var mergedWorkspaces: [MobileWorkspacePreview] = []
        mergedWorkspaces.reserveCapacity(workspaces.count + remoteWorkspaces.count)
        var emittedWindowIDs: Set<String> = []
        for workspace in workspaces {
            guard let windowID = workspace.windowID, let remoteSlice = remoteByWindowID[windowID] else {
                mergedWorkspaces.append(workspace)
                continue
            }
            if emittedWindowIDs.insert(windowID).inserted {
                mergedWorkspaces.append(contentsOf: remoteSlice)
            }
        }
        for windowID in windowOrder where !emittedWindowIDs.contains(windowID) {
            mergedWorkspaces.append(contentsOf: remoteByWindowID[windowID] ?? [])
        }
        for remoteWorkspace in remoteWithoutWindowID {
            if let existingIndex = mergedWorkspaces.firstIndex(where: { $0.id == remoteWorkspace.id }) {
                mergedWorkspaces[existingIndex] = remoteWorkspace
            } else {
                mergedWorkspaces.append(remoteWorkspace)
            }
        }
        return mergedWorkspaces
    }

    func mergeRemoteWorkspaceGroups(
        _ remoteGroups: [MobileSyncWorkspaceListResponse.Group],
        replacingGroupsAnchoredIn replacedWorkspaceIDs: Set<MobileWorkspacePreview.ID> = []
    ) {
        guard !remoteGroups.isEmpty || !replacedWorkspaceIDs.isEmpty else { return }
        let remoteGroupIDs = Set(remoteGroups.map { MobileWorkspaceGroupPreview.ID(rawValue: $0.id) })
        var mergedGroups = workspaceGroups
        if !replacedWorkspaceIDs.isEmpty {
            mergedGroups.removeAll { group in
                replacedWorkspaceIDs.contains(group.anchorWorkspaceID) && !remoteGroupIDs.contains(group.id)
            }
        }
        var indexByID: [MobileWorkspaceGroupPreview.ID: Int] = [:]
        for (index, group) in mergedGroups.enumerated() where indexByID[group.id] == nil {
            indexByID[group.id] = index
        }
        for remoteGroup in remoteGroups.map({ MobileWorkspaceGroupPreview(remote: $0) }) {
            if let existingIndex = indexByID[remoteGroup.id] {
                mergedGroups[existingIndex] = remoteGroup
            } else {
                indexByID[remoteGroup.id] = mergedGroups.count
                mergedGroups.append(remoteGroup)
            }
        }
        workspaceGroups = mergedGroups
    }
}
