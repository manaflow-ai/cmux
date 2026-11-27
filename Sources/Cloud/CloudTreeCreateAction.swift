import CmuxCloud
import CmuxSurfaceCatalogModel
import SwiftUI

/// A persistent create row in its owning Cloud category: New Workspace at the
/// top of a machine's workspaces, and New Terminal and New Display leading
/// their tabs. New Cloud Machine is the panel's button above the tree
/// (`CloudNewMachineButton`).
enum CloudTreeCreateAction: Equatable {
    case newWorkspace(SurfaceMachineID)
    /// Leads a Cloud machine's Terminals tab.
    case newTerminal(SurfaceMachineID)
    /// Leads a Cloud machine's Displays tab. `canCreate` is false while guest
    /// display discovery is pending; the row looks the same, does nothing,
    /// and its tooltip says why.
    case newDisplay(SurfaceMachineID, canCreate: Bool)
    /// Leads an account type's group in the CodeRouter section.
    case newCoderouterAccount(CoderouterProvider)

    var title: String {
        switch self {
        case .newWorkspace:
            return String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        case .newTerminal:
            return String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")
        case .newDisplay:
            return String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display")
        case .newCoderouterAccount(let provider):
            return provider.newAccountTitle
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .newWorkspace: return "CloudMachineNewWorkspaceAction"
        case .newTerminal: return "CloudMachineNewTerminalAction"
        case .newDisplay: return "CloudMachineNewDisplayAction"
        case .newCoderouterAccount(let provider): return "CoderouterNew\(provider.title)AccountAction"
        }
    }

    var machine: SurfaceMachineID {
        switch self {
        case .newWorkspace(let machine), .newTerminal(let machine), .newDisplay(let machine, _): return machine
        case .newCoderouterAccount: return .cloud("coderouter-section")
        }
    }

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
        case .newDisplay(let machine, let canCreate):
            guard canCreate else {
                actions.showHint(unavailableHelp ?? CloudGuestDisplaySnapshot.unavailableMessage)
                return
            }
            CloudTreeRowHoverButtons.performDisplayCreationIfAvailable(canCreate) {
                actions.newDisplay(machine)
            }
        case .newCoderouterAccount(let provider):
            actions.addCoderouterAccount(provider)
        }
    }
}
