import CmuxSurfaceCatalogModel

extension CloudTreeNodeBuilder {
    static func appendWorkspaceCreateAction(to rows: inout [CloudTreeNode], machine: SurfaceMachineID) {
        guard case .cloud = machine else { return }
        rows.append(CloudTreeNode(
            id: "\(nodeID(workspacesGroup: machine))/new-workspace",
            kind: .createAction(.newWorkspace(machine))
        ))
    }
}
