/// Adds persistent create rows at their category boundaries after the catalog tree is built.
enum CloudTreeCreateActionBuilder {
    static func add(to nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        for node in nodes {
            node.children = add(to: node.children)
            switch node.kind {
            case .cloudMachinesSection(let canCreateMachine, _):
                let machineActionID = "cloud-machines-section/new-cloud-vm"
                if canCreateMachine {
                    if let existingIndex = node.children.firstIndex(where: { $0.id == machineActionID }) {
                        let action = node.children.remove(at: existingIndex)
                        node.children.insert(action, at: 0)
                    } else {
                        node.children.insert(CloudTreeNode(id: machineActionID, kind: .createAction(.newCloudVM)), at: 0)
                    }
                } else {
                    node.children.removeAll { $0.id == machineActionID }
                }
            case .workspacesGroup(let machine)
                where (machine.cloudMachineID != nil || machine.isDevice) && !node.children.contains(where: { $0.structureTag == "createAction" }):
                node.children.append(CloudTreeNode(
                    id: "\(CloudTreeNodeBuilder.nodeID(workspacesGroup: machine))/new-workspace",
                    kind: .createAction(.newWorkspace(machine))
                ))
            default:
                break
            }
        }
        return nodes
    }
}
