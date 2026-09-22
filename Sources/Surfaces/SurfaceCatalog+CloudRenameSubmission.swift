import Foundation

extension SurfaceCatalog {
    /// Propagates a local workspace title through the catalog's ordered remote lane.
    func propagateCloudWorkspaceRename(
        workspace: Workspace,
        localTitle: String?,
        previousCustomTitle: String?,
        previousCustomTitleSource: Workspace.CustomTitleSource? = .user
    ) {
        cloudWorkspaceRenameService.propagate(
            workspace: workspace,
            localTitle: localTitle,
            previousCustomTitle: previousCustomTitle,
            previousCustomTitleSource: previousCustomTitleSource,
            catalog: self
        )
    }

    /// Propagates a local pane title through the exact remote tab placement.
    func propagateCloudTerminalRename(
        workspace: Workspace,
        panelID: UUID,
        resource: SurfaceResource,
        name: String,
        previousCustomTitle: String?,
        previousCustomTitleSource: Workspace.CustomTitleSource? = .user
    ) {
        cloudWorkspaceRenameService.propagateTerminalRename(
            workspace: workspace,
            panelID: panelID,
            resource: resource,
            name: name,
            previousCustomTitle: previousCustomTitle,
            previousCustomTitleSource: previousCustomTitleSource,
            catalog: self
        )
    }


    /// Register local intent before yielding the main actor. Otherwise an already
    /// queued graph callback can overwrite the edit before the async write starts.
    @discardableResult
    func enqueueRemoteWorkspaceRename(on machine: SurfaceMachineID, id: String, name: String,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> Task<Void, Error> {
        let provider = provider(for: machine)
        return cloudRenameCoordinator.enqueue(key: .workspace(machine: machine, id: id), pendingName: name, onFailure: onFailure, operation: { [weak self] in
            guard let provider, self?.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
            try await provider.renameRemoteWorkspace(id: id, name: name)
        })
    }

    /// The same admission boundary for placement-local terminal names and clears.
    @discardableResult
    func enqueueRemoteTabRename(on machine: SurfaceMachineID, id: String, name: String,
        expectedName: String? = nil,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> Task<Void, Error> {
        let provider = provider(for: machine)
        return cloudRenameCoordinator.enqueue(key: .tab(machine: machine, id: id), pendingName: name, onFailure: onFailure, operation: { [weak self] in
            guard let provider, self?.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
            if let expectedName {
                try await provider.renameRemoteTab(id: id, name: name, expectedName: expectedName)
            } else {
                try await provider.renameRemoteTab(id: id, name: name)
            }
        })
    }
}
