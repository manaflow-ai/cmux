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
        cloudWorkspaceRenameService.bind(
            localWorkspaceID: localWorkspaceID,
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            isBase: isBase,
            generatedTitle: generatedTitle
        )
        // A person can rename the local placeholder before the remote workspace
        // receipt arrives. Once binding supplies that identity, send the user
        // title through the same ordered lane as every later rename.
        if let workspace = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID),
           let title = workspace.customTitle,
           workspace.effectiveCustomTitleSource == .user,
           !Self.isGeneratedTitle(title, generatedTitle: generatedTitle),
           workspace.cloudVMBinding?.remoteWorkspaceID?.isEmpty == false {
            propagateCloudWorkspaceRename(
                workspace: workspace,
                localTitle: title,
                previousCustomTitle: generatedTitle,
                previousCustomTitleSource: .user
            )
        }
        requestCloudWorkspaceProjection(localWorkspaceID)
        cloudWorkspaceRenameService.updateCloudDirectories(localWorkspaceID: localWorkspaceID, catalog: self)
    }

    private static func isGeneratedTitle(_ title: String, generatedTitle: String?) -> Bool {
        guard let generatedTitle else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
            == generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
