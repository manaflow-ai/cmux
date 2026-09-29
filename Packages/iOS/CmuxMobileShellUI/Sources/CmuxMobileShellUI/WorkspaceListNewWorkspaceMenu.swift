import CmuxMobileSupport
import SwiftUI

struct WorkspaceListNewWorkspaceMenu: View, Equatable {
    let value: WorkspaceListNewWorkspaceMenuValue
    let actions: WorkspaceListNewWorkspaceMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        if value.asksForComputer, actions.createWorkspaceOnComputer != nil {
            computerMenu
        } else {
            singleComputerMenu
        }
    }

    /// One scoped computer, or the only available computer under All
    /// Computers: the tap creates directly and the long press keeps the
    /// existing group action.
    private var singleComputerMenu: some View {
        Menu {
            if value.canCreate {
                Button {
                    actions.createWorkspace()
                } label: {
                    Label(
                        L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
            } else if let target = value.singleConnectedTarget,
                      actions.createWorkspaceOnComputer != nil {
                Button {
                    actions.createWorkspaceOnComputer?(target)
                } label: {
                    Label(
                        L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
            }
            groupButton
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            guard value.isEnabled else { return }
            actions.createWorkspace()
        }
        .disabled(!value.isEnabled)
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    /// Several computers under All Computers: the tap asks where the new
    /// workspace goes instead of silently using the foreground Mac.
    private var computerMenu: some View {
        Menu {
            Section(L10n.string("mobile.workspace.new", defaultValue: "New Workspace")) {
                ForEach(value.computerTargets) { target in
                    Button {
                        guard target.isConnected else { return }
                        actions.createWorkspaceOnComputer?(target)
                    } label: {
                        Text(
                            String(
                                format: L10n.string(
                                    "mobile.workspace.newOnMachine",
                                    defaultValue: "New Workspace on %@"
                                ),
                                target.name
                            )
                        )
                        Image(systemName: target.systemImage)
                    }
                    .disabled(!target.isConnected)
                    .accessibilityIdentifier("MobileNewWorkspaceOnComputer-\(target.id)")
                }
            }
            groupButton
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!value.isEnabled)
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    @ViewBuilder
    private var groupButton: some View {
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
    }
}
