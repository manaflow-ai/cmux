import Foundation

extension MachinesPanelView {
    var cloudTreeNodeActions: CloudTreeNodeActions {
        CloudTreeNodeActions.bound(
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { AppDelegate.shared?.tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                AppDelegate.shared?.tabManager?.selectedTabId = workspaceID
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
