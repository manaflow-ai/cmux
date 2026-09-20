import Foundation

extension AppDelegate {
    /// Captures the initiating window while reusing the sidebar/socket creation path.
    func makeDeviceWorkspaceCreationCoordinator(
        operations: CloudWorkspaceOperationController,
        catalog: SurfaceCatalog
    ) -> DeviceWorkspaceCreationCoordinator {
        DeviceWorkspaceCreationCoordinator(operations: operations) { machine, manager in
            guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
            let originID = manager.selectedTabId
            var host = SurfaceCatalog.NewWorkspaceHost.appOptimistic
            host.create = { title in
                guard let workspace = manager.addWorkspaceIfActive(title: title, titleSource: .auto,
                    initialSurface: .cloudVMLoading, inheritWorkingDirectory: false, select: false,
                    autoWelcomeIfNeeded: false, allowTextBoxFocusDefault: false) else { throw CancellationError() }
                return (workspace.id, workspace.focusedPanelId)
            }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(machine: machine,
                provider: provider, catalog: catalog, name: nil, focus: false, host: host)
            guard !Task.isCancelled, manager.selectedTabId == originID,
                  let opened = result.opened,
                  let workspace = manager.tabs.first(where: { $0.id == opened.workspaceID }) else { return }
            manager.selectedTabId = workspace.id
            if let first = opened.projections.first { workspace.focusPanel(first.panelID) }
        }
    }
}
