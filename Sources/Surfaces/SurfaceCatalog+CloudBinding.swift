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
        generatedTitle: String? = nil
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
            generatedTitle: generatedTitle
        )
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
