import Foundation

extension MachinesPanelView {
    var accountFlow: HostAccountFlow? {
        AppDelegate.shared?.auth?.accountFlow
    }

    func createWorkspaceForSelection(_ machine: SurfaceMachineID) {
        guard currentCreateSelection == .machine(machine) else { return }
        cloudTreeNodeActions.newWorkspace(machine)
    }

    func createTerminalForSelection(_ machine: SurfaceMachineID, _ workspaceID: String) {
        guard currentCreateSelection?.remoteWorkspace == CloudWorkspaceRemoteIdentity(machine: machine, workspaceID: workspaceID) else { return }
        cloudTreeNodeActions.newTerminal(machine, workspaceID)
    }

    /// A retained menu snapshot is usable only in its original account and current tree.
    var currentCreateSelection: CloudTreeCreateSelection? {
        guard authState == .signedIn,
              let accountID = accountFlow?.currentIdentity?.id,
              let selectedCreateSelection,
              selectedCreateSelection.accountID == accountID else { return nil }
        return selectedCreateSelection.selection.validated(in: CloudTreeNodeBuilder.nodes(
            machines: viewModel.machines, pendingCreates: viewModel.pendingCreates,
            snapshot: viewModel.catalog, localWorkspaces: viewModel.localWorkspaces
        ))
    }

    var cloudTreeNodeActions: CloudTreeNodeActions {
        CloudTreeNodeActions.bound(
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { [weak tabManager] in tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                tabManager.selectedTabId = workspaceID
            },
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() },
            onFailure: { [weak viewModel] description in viewModel?.noteTreeFailure(description) },
            refresh: { [weak viewModel] in viewModel?.refresh(tree: true) }
        )
    }

    func machineDisplayName(_ machine: SurfaceMachineID) -> String {
        if let snapshot = viewModel.machines.first(where: { .cloud($0.id) == machine }) {
            return snapshot.displayName
        }
        if let info = viewModel.catalog.machines.first(where: { $0.id == machine }) {
            return info.name
        }
        return machine.rawValue
    }
}
