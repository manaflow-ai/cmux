import Foundation

extension CloudTreeOutlineView.Coordinator {
    func selectionContext(for node: CloudTreeNode) -> CloudTreeCreateSelection? {
        switch node.kind {
        case .machine(let machine, _):
            return .machine(.cloud(machine.id))
        case .workspacesGroup(let machine), .terminalsPool(let machine, _), .displaysPool(let machine, _), .portsGroup(let machine), .browsersGroup(let machine):
            return machine.isLocal ? nil : .machine(machine)
        case .workspace(let machine, let workspace, _, _, _):
            return .workspace(machine: machine, workspaceID: workspace.id, workspaceName: workspace.name)
        case .createWorkspace(let machine, _):
            return .machine(machine)
        case .createTerminal(let machine, let workspaceID, let workspaceName):
            return .workspace(machine: machine, workspaceID: workspaceID, workspaceName: workspaceName)
        default:
            return nil
        }
    }
}
