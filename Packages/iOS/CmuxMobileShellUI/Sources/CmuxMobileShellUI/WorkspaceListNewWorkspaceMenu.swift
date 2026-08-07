import CmuxMobileSupport
import SwiftUI

struct WorkspaceListNewWorkspaceMenu: View, Equatable {
    let value: WorkspaceListNewWorkspaceMenuValue
    let actions: WorkspaceListNewWorkspaceMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        Menu {
            Button {
                guard value.canCreate else { return }
                actions.createWorkspace()
            } label: {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus")
            }
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
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
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            guard value.canCreate else { return }
            actions.createWorkspace()
        }
        .disabled(!value.canCreate)
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }
}
