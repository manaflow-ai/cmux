import Foundation

extension SurfaceCatalog {
    /// Register local intent before yielding the main actor. Otherwise an already
    /// queued graph callback can overwrite the edit before the async write starts.
    func enqueueRemoteWorkspaceRename(on machine: SurfaceMachineID, id: String, name: String) -> Task<Void, Error> {
        let provider = provider(for: machine)
        return cloudRenameCoordinator.enqueue(key: .workspace(machine: machine, id: id), pendingName: name) { [weak self] in
            guard let provider, self?.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
            try await provider.renameRemoteWorkspace(id: id, name: name)
        }
    }

    /// The same admission boundary for placement-local terminal names and clears.
    func enqueueRemoteTabRename(on machine: SurfaceMachineID, id: String, name: String) -> Task<Void, Error> {
        let provider = provider(for: machine)
        return cloudRenameCoordinator.enqueue(key: .tab(machine: machine, id: id), pendingName: name) { [weak self] in
            guard let provider, self?.provider(for: machine) === provider else { throw SurfaceCatalogError.noProvider(machine) }
            try await provider.renameRemoteTab(id: id, name: name)
        }
    }
}
