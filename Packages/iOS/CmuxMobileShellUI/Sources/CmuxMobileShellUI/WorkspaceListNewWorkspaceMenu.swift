import CmuxMobileSupport
import SwiftUI
import UIKit

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

    /// One computer to create on: tap creates, long-press offers a group.
    private var singleComputerMenu: some View {
        Menu {
            Button {
                guard value.canCreate else { return }
                actions.createWorkspace()
            } label: {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus")
            }
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
            groupButton
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

    /// Several computers under "All Computers": tap asks where the new
    /// workspace goes (HIG Menus: a menu offers a choice the button alone
    /// can't make; every item carries the same kind of status icon).
    private var computerMenu: some View {
        Menu {
            Section(L10n.string("mobile.workspace.new", defaultValue: "New Workspace")) {
                ForEach(value.computerTargets) { target in
                    Button {
                        guard value.canCreate else { return }
                        actions.createWorkspaceOnComputer?(target)
                    } label: {
                        // Bare Text/Text/Image tuple: UIMenu reads title,
                        // subtitle, then icon (see WorkspaceMacTitlePicker).
                        Text(target.name)
                        if let statusText = target.statusText {
                            Text(statusText)
                        }
                        Image(uiImage: Self.statusDot(target.statusColor))
                    }
                    .accessibilityIdentifier("ssh.addMenu.computer.\(target.name)")
                }
            }
            if value.canCreateGroup {
                Section {
                    groupButton
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!value.canCreate)
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

    /// Menu item images render as templates; bake the status color in so the
    /// dot keeps it, like the status dots in the lists.
    private static func statusDot(_ color: Color) -> UIImage {
        let image = UIImage(systemName: "circle.fill") ?? UIImage()
        return image.withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }
}
