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
        if machine.freeAccess == .expired {
            items.append(item(String(localized: "machines.menu.upgradeToReconnect", defaultValue: "Upgrade to Reconnect\u{2026}")) { actions.promptUpgrade() })
        } else {
            items.append(item(String(localized: "machines.menu.openShell", defaultValue: "Open Shell")) { nodeActions.newTerminal(.cloud(id), nil) })
            items.append(item(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) { nodeActions.newWorkspace(.cloud(id)) })
            if machine.isDesktop {
                items.append(item(String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")) {
                    nodeActions.project(SurfaceResourceID(machine: .cloud(id), kind: .display, key: SurfaceResourceID.desktopDisplayKey), .split, true)
                })
            }
            items.append(item(String(localized: "cloudTree.menu.openFullClient", defaultValue: "Open Full cmux-tui Client")) { actions.runCommand(id, ["vm", "tui"]) })
        }
        if machine.freeAccess != .expired, machine.capabilities.sizing {
            items.append(CloudTreeResizeMenu.item(machine: machine, id: id, action: actions))
        }
        items.append(item(String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")) { nodeActions.refresh() })
        items.append(.separator())
        items.append(item(String(localized: "machines.menu.rename", defaultValue: "Rename\u{2026}")) { actions.promptRename(id, machine.label) })
        if let address = machine.privateAddress {
            items.append(item(String(localized: "machines.menu.copyIPAddress", defaultValue: "Copy IP Address")) { [nodeActions] in nodeActions.copyToPasteboard(address) })
        }
        items.append(item(String(localized: "machines.menu.status", defaultValue: "Status")) { actions.runCommand(id, ["vm", "status"]) })
        // Only verbs this provider can honor: a Checkpoint that answers 502 is not a verb.
        if machine.capabilities.snapshot {
            items.append(item(String(localized: "machines.menu.checkpoint", defaultValue: "Checkpoint")) { actions.runCommand(id, ["vm", "snapshot"]) })
        }
        if machine.capabilities.fork {
            items.append(item(String(localized: "machines.menu.fork", defaultValue: "Fork")) { actions.runCommand(id, ["vm", "fork"]) })
        }
        items.append(.separator())
        items.append(item(String(localized: "machines.menu.delete", defaultValue: "Delete…")) { actions.confirmDelete(id) })
        return items
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
