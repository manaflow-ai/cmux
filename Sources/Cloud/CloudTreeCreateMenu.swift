import SwiftUI

/// Header create menu. The icon stays in the existing chrome, while the menu
/// names the object being created and scopes it to the current selection.
struct CloudTreeCreateMenu: View {
    let selection: CloudTreeCreateSelection?
    let machineName: (SurfaceMachineID) -> String
    let perform: (CloudTreeCreateAction) -> Void

    private var model: CloudTreeCreateMenuModel {
        CloudTreeCreateMenuModel(selection: selection, machineName: machineName)
    }

    var body: some View {
        Menu {
            ForEach(Array(model.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) {
                    perform(action)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                Text(String(localized: "machines.newMenu.title", defaultValue: "New…"))
                    .cmuxFont(size: 11)
            }
            .frame(minWidth: 42, minHeight: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(minWidth: 42, minHeight: 20)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(.secondary)
        .help(String(localized: "machines.newMenu.tooltip", defaultValue: "New…"))
        .accessibilityLabel(String(localized: "machines.newMenu.accessibilityLabel", defaultValue: "New…"))
        .accessibilityIdentifier("CloudMachinesCreateMenu")
    }
}
