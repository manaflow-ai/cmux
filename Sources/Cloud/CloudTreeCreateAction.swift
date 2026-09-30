import CmuxCloud
import CmuxSurfaceCatalogModel
import SwiftUI

/// A persistent create row rendered at its owning Cloud category boundary.
enum CloudTreeCreateAction: Equatable {
    case newCloudVM
    case newWorkspace(SurfaceMachineID)

    var title: String {
        switch self {
        case .newCloudVM:
            return String(localized: "cloudTree.action.newCloudMachine", defaultValue: "New Cloud Machine")
        case .newWorkspace:
            return String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .newCloudVM: return "CloudMachinesNewCloudVMAction"
        case .newWorkspace: return "CloudMachineNewWorkspaceAction"
        }
    }

    var machine: SurfaceMachineID {
        switch self {
        case .newCloudVM: return .cloud("cloud-machines-section")
        case .newWorkspace(let machine): return machine
        }
    }

    @MainActor
    func perform(_ actions: CloudTreeNodeActions) {
        switch self {
        case .newCloudVM:
            actions.newMachine()
        case .newWorkspace(let machine):
            actions.newWorkspace(machine)
        }
    }
}
