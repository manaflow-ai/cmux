import Foundation

/// Header destinations are explicit. Selecting a workspace also keeps its parent create verb.
struct CloudTreeCreateMenuModel: Equatable {
    let actions: [CloudTreeCreateAction]

    init(selection: CloudTreeCreateSelection?, machineName: (SurfaceMachineID) -> String) {
        var actions: [CloudTreeCreateAction] = [.machine]
        switch selection {
        case .machine(let machine):
            actions.append(.workspace(machine: machine, name: machineName(machine)))
        case .workspace(let machine, let workspaceID, let workspaceName):
            actions.append(.workspace(machine: machine, name: machineName(machine)))
            actions.append(.terminal(machine: machine, workspaceID: workspaceID, name: workspaceName))
        case nil:
            break
        }
        self.actions = actions
    }
}
