import CmuxSurfaceCatalogModel
import Foundation

extension AppDelegate {
    /// Captures the initiating window while reusing the sidebar/socket creation path.
    func makeDeviceWorkspaceCreationCoordinator(
        operations: CloudWorkspaceOperationController,
        catalog: SurfaceCatalog
    ) -> DeviceWorkspaceCreationCoordinator {
        DeviceWorkspaceCreationCoordinator(operations: operations) { machine, manager in
            guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
            // Any navigation while the create runs, even back to this workspace, wins.
            let revision = manager.cloudWorkspaceSelection.revision
            let host = CloudWorkspaceCreationHost(manager: manager)
            // The tree reveals the row only if this create selects its workspace.
            let reveals = catalog.cloudWorkspaceCreationCoordinator.reveals
            let reveal = reveals.begin(in: manager)
            var isRevealed = false
            defer { if !isRevealed { reveals.withdraw(reveal) } }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(machine: machine,
                provider: provider, catalog: catalog, name: nil, focus: false, host: host)
            guard !Task.isCancelled, manager.cloudWorkspaceSelection.revision == revision,
                  let opened = result.opened,
                  let workspace = manager.tabs.first(where: { $0.id == opened.workspaceID }) else { return }
            manager.selectedTabId = workspace.id
            if let first = opened.projections.first { workspace.focusPanel(first.panelID) }
            reveals.receive(reveal, machine: machine, remoteWorkspaceID: result.workspace.id)
            isRevealed = true
        }
    }
}
