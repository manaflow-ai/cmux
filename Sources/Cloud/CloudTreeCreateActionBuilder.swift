import CmuxCloud

/// Adds persistent create rows to their categories after the catalog tree is built.
/// Cloud Machines leads with its create rows, under the header that owns them;
/// a machine's Workspaces category ends with its own New Workspace.
enum CloudTreeCreateActionBuilder {
    static let newCloudMachineNodeID = "cloud-machines-section/new-cloud-vm"
    static let newWorkspaceNodeID = "cloud-machines-section/new-workspace"

    static func add(to nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        for node in nodes {
            node.children = add(to: node.children)
            switch node.kind {
            case .cloudMachinesSection(let canCreateMachine, _):
                guard canCreateMachine,
                      !node.children.contains(where: { $0.id == newCloudMachineNodeID }) else { break }
                var actions = [CloudTreeNode(id: newCloudMachineNodeID, kind: .createAction(.newCloudVM))]
                if hasWorkspaceDestination(node.children) {
                    actions.append(CloudTreeNode(id: newWorkspaceNodeID, kind: .createAction(.newWorkspaceOnResolvedMachine)))
                }
                node.children = actions + node.children
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

    /// The section's New Workspace resolves its machine the way Cmd-N does, so it
    /// is offered only while a listed Cloud machine can receive a workspace, by
    /// the same rule Cmd-N's resolver applies (``cmuxApp/cloudWorkspaceTargetMachineIDs``).
    /// A create still in flight, a locked machine, or an empty or unloaded fleet
    /// has no destination, and the row would only end in a "no machine" alert.
    static func hasWorkspaceDestination(_ children: [CloudTreeNode]) -> Bool {
        children.contains { child in
            guard case .machine(let machine, _) = child.kind else { return false }
            return !machine.id.isEmpty && machine.acceptsNewWorkspaces
        }
    }
}
