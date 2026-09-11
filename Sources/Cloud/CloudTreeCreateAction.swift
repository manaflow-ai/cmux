import Foundation

/// A named creation destination shared by header, context, hover, and add-row controls.
enum CloudTreeCreateAction: Equatable {
    case machine
    case workspace(machine: SurfaceMachineID, name: String)
    case terminal(machine: SurfaceMachineID, workspaceID: String?, name: String)

    var title: String {
        switch self {
        case .machine:
            return String(localized: "machines.menu.newMachine", defaultValue: "New Machine…")
        case .workspace(_, let name):
            return String(format: String(localized: "cloudTree.menu.newWorkspaceOnMachine", defaultValue: "New Workspace on %@"), name)
        case .terminal(let machine, nil, let name):
            if machine.isLocal {
                return String(localized: "cloudTree.menu.newTerminalOnThisMac", defaultValue: "New Terminal on This Mac")
            }
            return String(format: String(localized: "cloudTree.menu.newTerminalWithoutWorkspace", defaultValue: "New Terminal on %@ (No Workspace)"), name)
        case .terminal(_, _, let name):
            return String(format: String(localized: "cloudTree.menu.newTerminalInWorkspace", defaultValue: "New Terminal in %@"), name)
        }
    }

    var rowTitle: String {
        switch self {
        case .machine: return title
        case .workspace: return String(localized: "cloudTree.row.newWorkspace", defaultValue: "New Workspace")
        case .terminal: return String(localized: "cloudTree.row.newTerminal", defaultValue: "New Terminal")
        }
    }

    init?(row: CloudTreeNode.Kind) {
        switch row {
        case .createWorkspace(let machine, let name): self = .workspace(machine: machine, name: name)
        case .createTerminal(let machine, let id, let name): self = .terminal(machine: machine, workspaceID: id, name: name)
        default: return nil
        }
    }

    @MainActor
    func perform(newMachine: () -> Void, nodeActions: CloudTreeNodeActions) {
        switch self {
        case .machine: newMachine()
        case .workspace(let machine, _): nodeActions.newWorkspace(machine)
        case .terminal(let machine, let workspaceID, _): nodeActions.newTerminal(machine, workspaceID)
        }
    }
}
