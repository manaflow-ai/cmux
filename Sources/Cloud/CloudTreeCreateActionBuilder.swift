import CmuxCloud

/// Adds persistent create rows to their categories after the catalog tree is built.
/// A machine's Workspaces category leads with its own New Workspace. Account
/// creation is a section-level menu, so provider groups contain accounts only.
/// New Cloud Machine is not a row: the Cloud panel shows it as a button above
/// the tree.
enum CloudTreeCreateActionBuilder {
    static func add(to nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        for node in nodes {
            node.children = add(to: node.children)
            switch node.kind {
            case .cloudMachinesSection:
                // New Cloud Machine is the button above the section
                // (`CloudNewMachineButton`); an empty fleet keeps its
                // "No cloud machines yet" line so the section still opens.
                break
            case .workspacesGroup(let machine)
                where (machine.cloudMachineID != nil || machine.isDevice) && !node.children.contains(where: { $0.structureTag == "createAction" }):
                node.children.insert(CloudTreeNode(
                    id: "\(CloudTreeNodeBuilder.nodeID(workspacesGroup: machine))/new-workspace",
                    kind: .createAction(.newWorkspace(machine))
                ), at: 0)
            // Account creation lives in the CodeRouter section header's Add
            // menu. Keeping a permanent "New … Account" child in every
            // provider group made the account roster read like a file tree
            // and repeated the same action for every provider.
            default:
                break
            }
        }
        return nodes
    }
}
