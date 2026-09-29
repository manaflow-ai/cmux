import CmuxCloud
import CmuxSurfaceCatalogModel
import SwiftUI

/// A persistent create row rendered at the end of its owning Cloud category.
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

/// The noninteractive label shared by a create row and its SwiftUI button.
struct CloudTreeCreateActionLabel: View {
    let action: CloudTreeCreateAction
    let style: CloudTreeStyle

    var body: some View {
        CloudTreeLeafRow(
            style: style,
            icon: "plus",
            tint: .secondary,
            title: action.title,
            titleWeight: .regular,
            titleDimmed: true
        )
    }
}

/// A hit-testable create row whose action remains visible without hover.
struct CloudTreeCreateActionView: View {
    let action: CloudTreeCreateAction
    let nodeActions: CloudTreeNodeActions
    let style: CloudTreeStyle

    var body: some View {
        Button {
            action.perform(nodeActions)
        } label: {
            CloudTreeCreateActionLabel(action: action, style: style)
                // Keep the glyph in the same leading icon slot as the owning
                // category. The normal tree rows do not have a leading button
                // inset; only the trailing edge needs breathing room for the
                // action background.
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: style.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
