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
            return String(localized: "command.cloudVM.new.title", defaultValue: "New Cloud VM")
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
            titleWeight: .medium
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
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: style.rowHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                        .padding(.horizontal, 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
