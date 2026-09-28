import CmuxMobileSupport
import SwiftUI

struct WorkspaceListNewWorkspaceMenu: View, Equatable {
    let value: WorkspaceListNewWorkspaceMenuValue
    let actions: WorkspaceListNewWorkspaceMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        Group {
            if value.canCreate {
                // The plain tap keeps its old meaning: create on the scoped
                // computer. The menu carries the alternatives.
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    actions.createWorkspace()
                }
            } else {
                // Nothing to create on the scoped computer, so the tap opens
                // the menu of Cloud targets instead of dying on a guard.
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .disabled(!value.isEnabled)
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    @ViewBuilder
    private var menuContent: some View {
        if value.canCreate {
            Button {
                actions.createWorkspace()
            } label: {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus")
            }
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
        }
        if value.canCreateGroup {
            Button {
                guard value.canCreate else { return }
                actions.createWorkspaceGroup?()
            } label: {
                Label(
                    L10n.string("mobile.workspaceGroup.new", defaultValue: "New Workspace Group"),
                    systemImage: "folder.badge.plus"
                )
            }
            .accessibilityIdentifier("MobileNewWorkspaceGroupMenuItem")
        }
        if !value.cloudTargets.isEmpty {
            Section {
                ForEach(value.cloudTargets) { target in
                    Button {
                        actions.createWorkspaceOnCloudMachine?(target.hostID)
                    } label: {
                        Label(
                            String(
                                format: L10n.string(
                                    "mobile.workspace.newOnMachine",
                                    defaultValue: "New Workspace on %@"
                                ),
                                target.name
                            ),
                            systemImage: "cloud"
                        )
                    }
                    .disabled(!target.isConnected)
                    .accessibilityIdentifier("MobileNewWorkspaceOnCloudMachine-\(target.hostID)")
                }
            }
        }
    }
}
