import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Persists the machine and remote workspace identity behind a local workspace.
    @MainActor
    func bindCloudWorkspace(
        localWorkspaceID: UUID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String?,
        isBase: Bool? = nil,
        generatedTitle: String? = nil,
        remoteWorkspaceName: String? = nil
    ) {
        let workspaceBeforeBind = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID)
        let wasUnbound = workspaceBeforeBind?.cloudVMBinding?.remoteWorkspaceID?.isEmpty != false
        let titleBeforeBind = workspaceBeforeBind?.customTitle
        let sourceBeforeBind = workspaceBeforeBind?.effectiveCustomTitleSource
        let isLegacyGeneratedTitle = generatedTitle.map {
            titleBeforeBind?.trimmingCharacters(in: .whitespacesAndNewlines) ==
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && workspaceBeforeBind?.customTitleSource == nil
        } ?? false
        cloudWorkspaceRenameService.bind(
            localWorkspaceID: localWorkspaceID,
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            isBase: isBase,
            generatedTitle: generatedTitle,
            remoteWorkspaceName: remoteWorkspaceName
        )
        if generatedTitle != nil {
            nameInitialWorkspaceForWhatItIs(localWorkspaceID: localWorkspaceID, machine: machine,
                                            receiptName: remoteWorkspaceName)
        }
        // A remote id can arrive after a user edit. Submit that edit once, at
        // the first identity binding, before graph reconciliation can apply an
        // older snapshot. Repeated receipts never replay the old title.
        if wasUnbound,
           remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           sourceBeforeBind == .user,
           !isLegacyGeneratedTitle,
           let titleBeforeBind,
           let workspace = workspaceBeforeBind {
            propagateCloudWorkspaceRename(
                workspace: workspace,
                localTitle: titleBeforeBind,
                previousCustomTitle: titleBeforeBind,
                previousCustomTitleSource: sourceBeforeBind
            )
        }
        if let workspace = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID),
           let state = cloudStates[machine],
           (cloudStateObservations[machine] ?? .current).freshness == .current {
            cloudWorkspaceRenameService.reconcileRemoteWorkspaceName(
                workspace: workspace,
                machine: machine,
                state: state,
                catalog: self,
                observation: cloudStateObservations[machine] ?? .current
            )
        }
        reconcileDeviceNames(on: machine)
        requestCloudWorkspaceProjection(localWorkspaceID)
        cloudWorkspaceRenameService.updateCloudDirectories(localWorkspaceID: localWorkspaceID, catalog: self)
}

}

extension SurfaceCatalog {
    /// Records that this session created `machine`, so its first bind may name its
    /// first workspace (``nameInitialWorkspaceForWhatItIs(localWorkspaceID:machine:receiptName:)``).
    @MainActor
    func noteMachineCreatedThisSession(_ machine: SurfaceMachineID) {
        machinesAwaitingInitialWorkspaceName.insert(machine)
    }

    /// Replaces the daemon's counter name on a new machine's sole workspace with
    /// its project or machine label (``CloudInitialWorkspaceName``), on both
    /// sides: the local title now, and the daemon name through the shared
    /// rename queue, whose pending intent keeps reconciliation from flashing
    /// the counter name back. A failed rename leaves the daemon name, which
    /// the next reconciliation adopts again.
    ///
    /// Only a machine this session created qualifies (``noteMachineCreatedThisSession(_:)``).
    /// Opening an existing machine also binds with a generated title, and renaming
    /// its weeks-old `workspace-1` there would rename it on every device after
    /// wherever its focused terminal happens to be. The mark is spent once the
    /// machine's workspace list has been seen at a bind, named or not.
    @MainActor
    func nameInitialWorkspaceForWhatItIs(localWorkspaceID: UUID, machine: SurfaceMachineID, receiptName: String?) {
        guard machinesAwaitingInitialWorkspaceName.contains(machine),
              let workspace = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID),
              workspace.effectiveCustomTitleSource != .user,
              let remoteWorkspaceID = workspace.cloudVMBinding?.remoteWorkspaceID,
              !remoteWorkspaceID.isEmpty,
              provider(for: machine) != nil else { return }
        let key = CloudRenameCoordinator.Key.workspace(machine: machine, id: remoteWorkspaceID)
        guard pendingCloudRenameName(for: key) == nil else { return }
        let catalogSnapshot = self.snapshot
        let info = catalogSnapshot.machines.first { $0.id == machine }
        let known = info?.remoteWorkspaces == nil ? nil
            : CloudTreeNodeBuilder.remoteWorkspaces(info: info, resources: catalogSnapshot.resources(on: machine))
        let remote = known?.first { $0.id == remoteWorkspaceID }
        // The list is known: this bind decides, whatever it decides.
        if known != nil { machinesAwaitingInitialWorkspaceName.remove(machine) }
        let decision = CloudInitialWorkspaceName(
            remoteWorkspaceID: remoteWorkspaceID,
            remoteName: cloudStates[machine]?.lookupIndex.workspace(id: remoteWorkspaceID)?.name
                ?? remote?.name ?? receiptName,
            machineWorkspaceIDs: known?.map(\.id),
            workingDirectory: remote?.detail,
            machineLabel: info?.name,
            machineRawIDs: [machine.rawValue, machine.cloudMachineID, machine.tuiMachineID].compactMap { $0 }
        )
        guard let name = decision.replacement,
              let manager = workspace.owningTabManager ?? cloudWorkspaceRenameService.environment.tabManager(localWorkspaceID)
        else { return }
        _ = manager.setCustomTitle(tabId: localWorkspaceID, title: name, source: .remote,
                                   propagateToRemoteTmux: false, propagateToCloud: false)
        enqueueRemoteWorkspaceRename(on: machine, id: remoteWorkspaceID, name: name)
    }
}
