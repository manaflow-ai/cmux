import Foundation

extension CloudTreeNodeBuilder {
    static func nodeID(createWorkspace machine: SurfaceMachineID) -> String {
        "machine:\(machine.rawValue)/workspaces/create"
    }

    static func nodeID(createTerminal workspace: String, machine: SurfaceMachineID) -> String {
        "machine:\(machine.rawValue)/ws/\(workspace)/create-terminal"
    }
}
