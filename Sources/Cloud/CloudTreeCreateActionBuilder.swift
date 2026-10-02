import CmuxCloud

/// Adds persistent create rows to their categories after the catalog tree is built.
/// Cloud Machines leads with the resolved-machine New Workspace; a machine's
/// Workspaces category ends with its own New Workspace. New Cloud Machine is not
/// a row: the Cloud panel shows it as a button above the tree.
enum CloudTreeCreateActionBuilder {
    static let newWorkspaceNodeID = "cloud-machines-section/new-workspace"

    /// - Parameter fleetListIsCurrent: False while the fleet read is failing or
    ///   offline. Listed machines can be left over from an earlier read, and the
    ///   section's New Workspace re-reads the fleet, so it is withheld then.
    static func add(to nodes: [CloudTreeNode], fleetListIsCurrent: Bool = true) -> [CloudTreeNode] {
        for node in nodes {
            node.children = add(to: node.children, fleetListIsCurrent: fleetListIsCurrent)
            switch node.kind {
            case .cloudMachinesSection(let canCreateMachine, _):
                // New Cloud Machine is the button above the section
                // (`CloudNewMachineButton`), so the empty fleet's
                // double-click-only "New Machine" placeholder goes.
                guard canCreateMachine else { break }
                node.children.removeAll { $0.id == "cloud-machines-section/empty" || $0.id == newWorkspaceNodeID }
                if fleetListIsCurrent, hasWorkspaceDestination(node.children) {
                    node.children.insert(CloudTreeNode(id: newWorkspaceNodeID, kind: .createAction(.newWorkspaceOnResolvedMachine)), at: 0)
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
