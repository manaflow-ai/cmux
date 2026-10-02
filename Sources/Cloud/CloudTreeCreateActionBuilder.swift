import CmuxCloud

/// Adds persistent create rows to their categories after the catalog tree is built.
/// A machine's Workspaces category leads with its own New Workspace, and Cloud
/// Machines ends with Refresh Cloud Machines once it lists a machine. New
/// Cloud Machine is not a row: the Cloud panel shows it as a button above the
/// tree.
enum CloudTreeCreateActionBuilder {
    static let refreshNodeID = "cloud-machines-section/refresh"

    static func add(to nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        for node in nodes {
            node.children = add(to: node.children)
            switch node.kind {
            case .cloudMachinesSection(let canCreateMachine, _):
                // New Cloud Machine is the button above the section
                // (`CloudNewMachineButton`), so the empty fleet's
                // double-click-only "New Machine" placeholder goes.
                guard canCreateMachine else { break }
                node.children.removeAll { $0.id == "cloud-machines-section/empty" }
                if node.children.contains(where: { if case .machine = $0.kind { return true }; return false }),
                   !node.children.contains(where: { $0.id == refreshNodeID }) {
                    node.children.append(CloudTreeNode(id: refreshNodeID, kind: .createAction(.refreshCloudMachines)))
                }
            case .workspacesGroup(let machine)
                where (machine.cloudMachineID != nil || machine.isDevice) && !node.children.contains(where: { $0.structureTag == "createAction" }):
                node.children.insert(CloudTreeNode(
                    id: "\(CloudTreeNodeBuilder.nodeID(workspacesGroup: machine))/new-workspace",
                    kind: .createAction(.newWorkspace(machine))
                ), at: 0)
            default:
                break
            }
        }
        return nodes
    }
}
