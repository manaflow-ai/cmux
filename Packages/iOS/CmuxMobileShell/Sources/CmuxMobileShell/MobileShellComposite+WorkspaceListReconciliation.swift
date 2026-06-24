import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse,
        authoritativeForPendingClosures: Bool = true
    ) -> [MobileWorkspacePreview] {
        // Reconcile pending optimistic closes against this authoritative list
        // first: any id the Mac no longer reports is genuinely closed, so its
        // pending entry is retired. Ids the Mac still reports stay pending and
        // are filtered below.
        if authoritativeForPendingClosures {
            reconcileOptimisticClosures(
                against: response,
                macDeviceID: foregroundMacDeviceID ?? activeTicket?.macDeviceID
            )
        }
        return response.workspaces.compactMap { remoteWorkspace in
            var workspace = MobileWorkspacePreview(remote: remoteWorkspace)
            workspace.macDeviceID = activeTicket?.macDeviceID
            let foregroundMacID = foregroundMacDeviceID ?? activeTicket?.macDeviceID
            guard let existingWorkspace = workspaces.first(where: {
                workspaceMatchesRemoteID($0, remoteID: workspace.id, macDeviceID: foregroundMacID)
            }) else {
                return workspace
            }
            workspace.terminals = workspace.terminals.map { remoteTerminal in
                guard let existingTerminal = existingWorkspace.terminals.first(where: { $0.id == remoteTerminal.id }) else {
                    return remoteTerminal
                }
                var terminal = remoteTerminal
                terminal.viewportFit = existingTerminal.viewportFit
                return terminal
            }
            return workspace
        }
    }

    /// Retire pending optimistic closes that the Mac's authoritative list confirms
    /// are gone. Ids still present remain pending and filtered.
    func reconcileOptimisticClosures(
        against response: MobileSyncWorkspaceListResponse,
        macDeviceID: String?
    ) {
        guard !optimisticallyClosedWorkspaces.isEmpty else { return }
        let remoteIDs = Set(response.workspaces.map { MobileWorkspacePreview.ID(rawValue: $0.id) })
        for (id, snapshot) in optimisticallyClosedWorkspaces
            where pendingOptimisticClose(snapshot, canBeConfirmedByMacDeviceID: macDeviceID)
                && !remoteIDs.contains(snapshot.rpcWorkspaceID)
        {
            optimisticallyClosedWorkspaces.removeValue(forKey: id)
            optimisticallyClosedSelectedWorkspaceIDs.remove(id)
            optimisticallyClosedReplacementSelections.removeValue(forKey: id)
        }
    }

    func pendingOptimisticClose(
        _ snapshot: MobileWorkspacePreview,
        matchesRemoteID remoteID: MobileWorkspacePreview.ID,
        macDeviceID: String?
    ) -> Bool {
        snapshot.rpcWorkspaceID == remoteID
            && pendingOptimisticClose(snapshot, belongsToMacDeviceID: macDeviceID)
    }

    func pendingOptimisticClose(
        _ snapshot: MobileWorkspacePreview,
        belongsToMacDeviceID macDeviceID: String?
    ) -> Bool {
        guard let macDeviceID, !macDeviceID.isEmpty else { return true }
        guard let snapshotMacID = snapshot.macDeviceID, !snapshotMacID.isEmpty else { return true }
        return snapshotMacID == macDeviceID
    }

    func pendingOptimisticClose(
        _ snapshot: MobileWorkspacePreview,
        canBeConfirmedByMacDeviceID macDeviceID: String?
    ) -> Bool {
        guard let macDeviceID, !macDeviceID.isEmpty else {
            return snapshot.macDeviceID?.isEmpty ?? true
        }
        guard let snapshotMacID = snapshot.macDeviceID, !snapshotMacID.isEmpty else { return true }
        return snapshotMacID == macDeviceID
    }
}
