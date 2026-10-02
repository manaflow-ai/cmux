import CmuxCloud
import CmuxSurfaceCatalogModel
import SwiftUI

/// A persistent create row in its owning Cloud category: the resolved-machine
/// New Workspace under the Cloud Machines header, New Workspace at the end of a
/// machine's workspaces, and New Terminal leading its Terminals tab. New Cloud
/// Machine is the panel's button above the tree (`CloudNewMachineButton`).
enum CloudTreeCreateAction: Equatable {
    case newWorkspace(SurfaceMachineID)
    case newWorkspaceOnResolvedMachine
    /// Leads a Cloud machine's Terminals tab.
    case newTerminal(SurfaceMachineID)

    var title: String {
        switch self {
        case .newWorkspace, .newWorkspaceOnResolvedMachine:
            return String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        case .newTerminal:
            return String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .newWorkspace: return "CloudMachineNewWorkspaceAction"
        case .newWorkspaceOnResolvedMachine: return "CloudMachinesNewWorkspaceAction"
        case .newTerminal: return "CloudMachineNewTerminalAction"
        }
    }

    var machine: SurfaceMachineID {
        switch self {
        case .newWorkspace(let machine), .newTerminal(let machine): return machine
        case .newWorkspaceOnResolvedMachine: return .cloud("cloud-machines-section")
        }
    }

    @MainActor
    func perform(_ actions: CloudTreeNodeActions) {
        switch self {
        case .newWorkspace(let machine):
            actions.newWorkspace(machine)
        case .newWorkspaceOnResolvedMachine:
            actions.newWorkspaceOnResolvedMachine()
        case .newTerminal(let machine):
            actions.newTerminal(machine, nil)
        }
    }
}
