/// Adds persistent create rows at their category boundaries after the catalog tree is built.
enum CloudTreeCreateActionBuilder {
    static func add(to nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        for node in nodes {
            node.children = add(to: node.children)
            switch node.kind {
            case .cloudMachinesSection(let canCreateMachine, _):
                if canCreateMachine && !node.children.contains(where: { $0.id == "cloud-machines-section/new-cloud-vm" }) {
                    node.children.append(CloudTreeNode(id: "cloud-machines-section/new-cloud-vm", kind: .createAction(.newCloudVM)))
                }
                let hasCloudMachine = node.children.contains { child in
                    if case .machine(let machine, _) = child.kind { return machine.cloudMachineID != nil }
                    return false
                }
                if !hasCloudMachine && !node.children.contains(where: { $0.id == "cloud-machines-section/new-workspace" }) {
                    node.children.append(CloudTreeNode(id: "cloud-machines-section/new-workspace", kind: .createAction(.newWorkspaceOnResolvedMachine)))
                }
            case .workspacesGroup(let machine)
                where machine.cloudMachineID != nil && !node.children.contains(where: { $0.structureTag == "createAction" }):
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
