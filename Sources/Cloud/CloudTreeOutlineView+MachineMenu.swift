import CmuxCloud
import AppKit
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    func machineMenuItems(_ machine: MachineSnapshot) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let actions = machineActions
        let nodeActions = nodeActions
        let id = machine.id
        // Pin/Unpin leads and is available in every access state: a pin is a
        // local sidebar preference, not a verb the machine has to honor.
        items.append(item(
            machine.isPinned
                ? String(localized: "machines.row.unpin", defaultValue: "Unpin Machine")
                : String(localized: "machines.row.pin", defaultValue: "Pin Machine")
        ) { [weak self] in
            guard let machines = actions.setPinned(id, !machine.isPinned) else { return }
            self?.applyMachineOrder(machines)
        })
        items.append(contentsOf: machineReorderMenuItems(id: id))
        let verbs = machineMenuVerbs
        items.append(contentsOf: CloudMenuAppKitRenderer.items(verbs.openEntries(machine)))
        if machine.freeAccess != .expired, machine.capabilities.sizing {
            items.append(CloudTreeResizeMenu.item(machine: machine, id: id, action: actions))
        }
        items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
        items.append(.separator())
        items.append(contentsOf: CloudMenuAppKitRenderer.items(verbs.manageEntries(machine)))
        items.append(.separator())
        items.append(contentsOf: CloudMenuAppKitRenderer.items(verbs.deleteEntries(machine)))
        return items
    }

    /// The sidebar binds the shared machine verbs to the tree: shells and
    /// workspaces open through the catalog into the selected workspace.
    var machineMenuVerbs: CloudMachineMenuVerbs {
        let actions = machineActions
        let nodeActions = nodeActions
        return CloudMachineMenuVerbs(
            openShell: { nodeActions.newTerminal(.cloud($0), nil) },
            newWorkspace: { nodeActions.newWorkspace(.cloud($0)) },
            openDesktop: { id in
                nodeActions.project(SurfaceResourceID(machine: .cloud(id), kind: .display, key: SurfaceResourceID.desktopDisplayKey), .split, true)
            },
            runCommand: actions.runCommand,
            promptRename: actions.promptRename,
            copyToPasteboard: nodeActions.copyToPasteboard,
            confirmDelete: actions.confirmDelete,
            confirmDeleteNamed: actions.confirmDeleteNamed,
            promptUpgrade: actions.promptUpgrade
        )
    }

    /// A running create can be cancelled immediately; a failed one offers
    /// the same retry/dismiss verbs as its hover buttons plus the transcript.
    func pendingMachineMenuItems(_ operation: MachineCreateOperation) -> [NSMenuItem] {
        let create = machineActions.create
        let nodeActions = nodeActions
        let id = operation.id
        var items: [NSMenuItem] = []
        if operation.isCancellable {
            items.append(item(String(localized: "machines.pending.cancel", defaultValue: "Cancel Create")) { create.cancel(id) })
        } else if !operation.isReconciling {
            items.append(item(String(localized: "machines.pending.retry", defaultValue: "Retry Create")) { create.retry(id) })
            items.append(item(String(localized: "machines.pending.showError", defaultValue: "Show Error\u{2026}")) { create.showFailure(id) })
            items.append(item(String(localized: "machines.pending.copyError", defaultValue: "Copy Error")) { create.copyFailure(id) })
            items.append(.separator())
        }
        items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
        if operation.failureOutput != nil {
            items.append(.separator())
            items.append(item(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss")) { create.dismiss(id) })
        }
        return items
    }
}
