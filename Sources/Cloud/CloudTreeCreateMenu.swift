import SwiftUI

enum CloudTreeCreateSelection: Equatable {
    case machine(SurfaceMachineID)
    case workspace(machine: SurfaceMachineID, workspaceID: String, workspaceName: String)

    var workspaceID: String? {
        if case .workspace(_, let workspaceID, _) = self { return workspaceID }
        return nil
    }
}

/// Header create menu. The icon stays in the existing chrome, while the menu
/// names the object being created and scopes it to the current selection.
struct CloudTreeCreateMenu: View {
    let selection: CloudTreeCreateSelection?
    let machineName: (SurfaceMachineID) -> String
    let requestNewMachine: () -> Void
    let newWorkspace: (SurfaceMachineID) -> Void
    let newTerminal: (SurfaceMachineID, String) -> Void

    var body: some View {
        Menu {
            Button(String(localized: "machines.menu.newMachine", defaultValue: "New Machine…"), action: requestNewMachine)
            if let selection {
                Divider()
                switch selection {
                case .machine(let machine):
                    Button(
                        String(format: String(localized: "machines.menu.newWorkspaceOn", defaultValue: "New Workspace on %@"), machineName(machine))
                    ) {
                        newWorkspace(machine)
                    }
                case .workspace(let machine, let workspaceID, let workspaceName):
                    Button(
                        String(format: String(localized: "machines.menu.newTerminalIn", defaultValue: "New Terminal in %@"), workspaceName)
                    ) {
                        newTerminal(machine, workspaceID)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 20)
        .foregroundColor(.secondary)
        .help(String(localized: "machines.newMenu.tooltip", defaultValue: "New…"))
        .accessibilityLabel(String(localized: "machines.newMenu.accessibilityLabel", defaultValue: "New…"))
        .accessibilityIdentifier("CloudMachinesCreateMenu")
    }
}
