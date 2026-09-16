import CmuxCloudMachines

extension CloudTreeOutlineView.Coordinator {
    func machineSelection(for node: CloudTreeNode?) -> CloudWorkspaceMachineSelection {
        guard let node else { return .none }
        if case .pendingMachine = node.kind { return .pending }
        return node.machine.isLocal ? .local : .cloud(node.machine.rawValue)
    }

    func publishSelectedMachineSelection() {
        guard let nodeID = selection.nodeID else { onSelectionChange(.empty); return }
        guard let node = CloudTreeNodeBuilder.flattened(nodes).first(where: { $0.id == nodeID }) else { return }
        let next = CloudTreeSelection(nodeID: node.id, machine: machineSelection(for: node))
        selection = next
        onSelectionChange(next)
    }
}
