import CmuxCloud
import CmuxSurfaceCatalogModel
import SwiftUI

/// A persistent action row in its owning Cloud category: New Workspace at the
/// top of a machine's workspaces, New Terminal and New Display leading their
/// tabs, and Refresh Cloud Machines closing the Cloud Machines section. New
/// Cloud Machine is the panel's button above the tree (`CloudNewMachineButton`).
enum CloudTreeCreateAction: Equatable {
    case newWorkspace(SurfaceMachineID)
    /// Leads a Cloud machine's Terminals tab.
    case newTerminal(SurfaceMachineID)
    /// Leads a Cloud machine's Displays tab. `canCreate` is false while guest
    /// display discovery is pending; the row looks the same, does nothing,
    /// and its tooltip says why.
    case newDisplay(SurfaceMachineID, canCreate: Bool)
    /// The last row of Cloud Machines, above My Devices: trailing and as wide
    /// as its label.
    case refreshCloudMachines

    var title: String {
        switch self {
        case .newWorkspace:
            return String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        case .newTerminal:
            return String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")
        case .newDisplay:
            return String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display")
        case .refreshCloudMachines:
            return String(localized: "cloudTree.action.refreshCloudMachines", defaultValue: "Refresh Cloud Machines")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .newWorkspace: return "CloudMachineNewWorkspaceAction"
        case .newTerminal: return "CloudMachineNewTerminalAction"
        case .newDisplay: return "CloudMachineNewDisplayAction"
        case .refreshCloudMachines: return "CloudRefreshMachinesAction"
        }
    }

    var machine: SurfaceMachineID {
        switch self {
        case .newWorkspace(let machine), .newTerminal(let machine), .newDisplay(let machine, _): return machine
        case .refreshCloudMachines: return .cloud("cloud-machines-section")
        }
    }

    var icon: String {
        self == .refreshCloudMachines ? "arrow.clockwise" : "plus"
    }

    /// Sits at the trailing edge, as wide as its label, instead of on the
    /// icon grid.
    var isTrailing: Bool { self == .refreshCloudMachines }

    /// Why the row does nothing yet, shown as its tooltip.
    var unavailableHelp: String? {
        if case .newDisplay(_, false) = self { return CloudGuestDisplaySnapshot.unavailableMessage }
        return nil
    }

    @MainActor
    func perform(_ actions: CloudTreeNodeActions) {
        switch self {
        case .newWorkspace(let machine):
            actions.newWorkspace(machine)
        case .newTerminal(let machine):
            actions.newTerminal(machine, nil)
        case .refreshCloudMachines:
            actions.refresh()
        case .newDisplay(let machine, let canCreate):
            CloudTreeRowHoverButtons.performDisplayCreationIfAvailable(canCreate) {
                actions.newDisplay(machine)
            }
        }
    }
}
