import CmuxCloud
import CmuxSurfaceCatalogModel
import SwiftUI

/// A persistent create row in its owning Cloud category: first under the Cloud
/// Machines header, last in a machine's Workspaces category.
enum CloudTreeCreateAction: Equatable {
    case newCloudVM
    case newWorkspace(SurfaceMachineID)
    case newWorkspaceOnResolvedMachine

    var title: String {
        switch self {
        case .newCloudVM:
            return String(localized: "cloudTree.action.newCloudMachine", defaultValue: "New Cloud Machine")
        case .newWorkspace:
            return String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        case .newWorkspaceOnResolvedMachine:
            return String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .newCloudVM: return "CloudMachinesNewCloudVMAction"
        case .newWorkspace: return "CloudMachineNewWorkspaceAction"
        case .newWorkspaceOnResolvedMachine: return "CloudMachinesNewWorkspaceAction"
        }
    }

    var machine: SurfaceMachineID {
        switch self {
        case .newCloudVM: return .cloud("cloud-machines-section")
        case .newWorkspace(let machine): return machine
        case .newWorkspaceOnResolvedMachine: return .cloud("cloud-machines-section")
        }
    }

    @MainActor
    func perform(_ actions: CloudTreeNodeActions) {
        switch self {
        case .newCloudVM:
            actions.newMachine()
        case .newWorkspace(let machine):
            actions.newWorkspace(machine)
        case .newWorkspaceOnResolvedMachine:
            actions.newWorkspaceOnResolvedMachine()
        }
    }
}
