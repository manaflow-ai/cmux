import AppKit
import Foundation

extension MachinesPanelView {
    var creationWindow: NSWindow? {
        guard let app = AppDelegate.shared,
              let context = app.mainWindowContext(for: tabManager) else { return nil }
        return app.resolvedWindow(for: context)
    }

    var accountFlow: HostAccountFlow? {
        AppDelegate.shared?.auth?.accountFlow
    }

    func performCreateMenuAction(_ action: CloudTreeCreateAction, accountID: String?, newMachine: () -> Void) {
        guard let accountID, accountID == accountFlow?.currentIdentity?.id else { return }
        switch action {
        case .machine: break
        case .workspace(let machine, _):
            guard currentCreateSelection?.machineID == machine else { return }
        case .terminal(let machine, let workspaceID, _):
            guard let workspaceID,
                  currentCreateSelection?.remoteWorkspace == CloudWorkspaceRemoteIdentity(machine: machine, workspaceID: workspaceID) else { return }
        }
        action.perform(newMachine: newMachine, nodeActions: cloudTreeNodeActions)
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
        let accountID = accountFlow?.currentIdentity?.id
        return CloudTreeNodeActions.bound(
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { [weak tabManager] in tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                tabManager.selectedTabId = workspaceID
            },
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() },
            onFailure: { [weak viewModel] description in viewModel?.noteTreeFailure(description) },
            refresh: { [weak viewModel] in viewModel?.refresh(tree: true) },
            refreshMachine: { [weak viewModel] in viewModel?.refreshMachine($0) },
            authorizeCreation: { [weak viewModel] machine in
                guard let viewModel,
                      CloudMachinesFeature.isEnabled,
                      accountID != nil,
                      accountID == accountFlow?.currentIdentity?.id,
                      accountFlow?.isAuthenticated == true else { return false }
                switch CloudTreeCreationAvailability.resolve(machine: machine, machines: viewModel.machines) {
                case .allowed:
                    return true
                case .expired:
                    ProUpgradePresenter.present(source: .machinesPanelMachineAction)
                    return false
                case .unknown:
                    viewModel.noteTreeFailure(String(localized: "machines.create.needsRefresh", defaultValue: "Machine details are still loading. Refresh before creating a workspace or terminal."))
                    return false
                }
            }
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
