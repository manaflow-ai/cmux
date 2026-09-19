import Foundation

/// A create destination identified by its machine and, when applicable, workspace.
enum CloudTreeCreateSelection: Equatable {
    case machine(SurfaceMachineID)
    case workspace(machine: SurfaceMachineID, workspaceID: String, workspaceName: String)

    var remoteWorkspace: CloudWorkspaceRemoteIdentity? {
        guard case .workspace(let machine, let id, _) = self else { return nil }
        return CloudWorkspaceRemoteIdentity(machine: machine, workspaceID: id)
    }

    /// Reconciles the destination and display name against the same nodes the outline renders.
    func validated(in nodes: [CloudTreeNode]) -> Self? {
        for node in CloudTreeNodeBuilder.flattened(nodes) {
            switch (self, node.kind) {
            case (.machine(let id), .machine(let machine, _)) where id == .cloud(machine.id):
                return self
            case (.workspace(let machine, let id, _), .workspace(let rowMachine, let workspace, _, _, _))
                where machine == rowMachine && id == workspace.id:
                return .workspace(machine: machine, workspaceID: id, workspaceName: workspace.name)
            default:
                continue
            }
        }
        return nil
    }
}
