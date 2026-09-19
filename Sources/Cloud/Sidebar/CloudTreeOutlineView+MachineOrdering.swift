import AppKit
import CmuxCloudMachines

/// Native machine commands apply the persisted result before returning to
/// AppKit. All input paths share the same scoped store action and presentation.
extension CloudTreeOutlineView.Coordinator {
    @discardableResult
    func moveMachine(_ id: String, move: CloudMachinePinStore.Move, using actions: CloudMachineOrderingActions) -> Bool {
        guard let machines = actions.move(id, move) else { return false }
        applyMachineOrder(machines)
        return true
    }

    /// A boundary move is consumed even when it cannot change order, so a
    /// focused Cloud header never accidentally reorders the local workspace.
    func moveSelectedMachine(by offset: Int) -> Bool {
        guard let outlineView,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? CloudTreeNode,
              let id = node.machineOrderID else { return false }
        if let actions = machineActions.ordering {
            moveMachine(id, move: offset < 0 ? .up : .down, using: actions)
        }
        return true
    }

    private var machineMoveOptions: [(String, CloudMachinePinStore.Move)] {
        [
            (String(localized: "contextMenu.moveUp", defaultValue: "Move Up"), .up),
            (String(localized: "contextMenu.moveDown", defaultValue: "Move Down"), .down),
            (String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"), .top)
        ]
    }

    func machineReorderMenuItems(id: String) -> [NSMenuItem] {
        guard let actions = machineActions.ordering else { return [] }
        return machineMoveOptions.map { title, move in
            let item = item(title) { [weak self] in self?.moveMachine(id, move: move, using: actions) }
            item.isEnabled = actions.canMove(id, move)
            return item
        }
    }

    func configureMachineReorderAccessibility(_ cell: NSView, node: CloudTreeNode) {
        guard let id = node.machineOrderID, let actions = machineActions.ordering else {
            cell.setAccessibilityCustomActions(nil)
            return
        }
        cell.setAccessibilityCustomActions(machineMoveOptions.map { title, move in
            NSAccessibilityCustomAction(name: title, handler: { [weak self] in
                self?.moveMachine(id, move: move, using: actions) == true
            })
        })
    }

    /// This Mac and pending creates keep their slots. Reordering preserves
    /// adopted creation node IDs, child objects, and the outline's selection
    /// and expansion restoration; it never projects or reconnects a machine.
    func applyMachineOrder(_ machines: [MachineSnapshot]) {
        let current = organizationNodes
        let roots = Dictionary(current.compactMap { node -> (String, CloudTreeNode)? in
            guard let id = node.machineOrderID else { return nil }
            return (id, node)
        }, uniquingKeysWith: { first, _ in first })
        var updated = machines.compactMap { machine -> CloudTreeNode? in
            guard let node = roots[machine.id], case .machine(_, let info) = node.kind else { return nil }
            return CloudTreeNode(
                id: node.id, kind: .machine(machine, info), children: node.children, isPinned: machine.isPinned
            )
        }.makeIterator()
        applyOrganization(nodes: current.compactMap { node in
            node.canReorderMachine ? updated.next() : node
        })
    }
}
