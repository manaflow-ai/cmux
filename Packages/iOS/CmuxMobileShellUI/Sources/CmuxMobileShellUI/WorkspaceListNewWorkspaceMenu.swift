import CmuxMobileShell
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
        } else if !value.sshKinds.isEmpty, let create = actions.createSSHWorkspace {
            sshKindMenu(create: create)
        } else {
            singleComputerMenu
        }
    }

    /// One SSH computer: tap lists the kinds it can create (PRD D31). A
    /// host serves every kind at once, so there is no default to guess
    /// (HIG Menus: a menu offers a choice the button alone can't make).
    private func sshKindMenu(create: @escaping (MobileSSHWorkspaceKind) -> Void) -> some View {
        Menu {
            Section {
                kindItems(value.sshKinds, create: create)
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

    /// "New cmux-tui Workspace", "New tmux Session", "New Shell"; a kind the
    /// computer cannot create is dimmed with its reason as the subtitle.
    @ViewBuilder
    private func kindItems(
        _ kinds: [WorkspaceCreateKindOption],
        create: @escaping (MobileSSHWorkspaceKind) -> Void
    ) -> some View {
        ForEach(kinds) { option in
            Button {
                guard value.canCreate, option.unavailableReason == nil else { return }
                create(option.kind)
            } label: {
                Text(option.kind.sshNewItemTitle)
                if let reason = option.unavailableReason {
                    Text(reason)
                }
                Image(systemName: option.kind.sshSystemImage)
            }
            .disabled(option.unavailableReason != nil)
            .accessibilityIdentifier("ssh.addMenu.kind.\(option.kind.sshAccessibilityKey)")
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
                    if target.sshKinds.isEmpty {
                        Button {
                            guard value.canCreate else { return }
                            actions.createWorkspaceOnComputer?(target, nil)
                        } label: {
                            targetLabel(target)
                        }
                        .accessibilityIdentifier("ssh.addMenu.computer.\(target.name)")
                    } else {
                        // An SSH computer opens a submenu of the kinds it
                        // can create; Macs keep creating directly.
                        Menu {
                            kindItems(target.sshKinds) { kind in
                                actions.createWorkspaceOnComputer?(target, kind)
                            }
                        } label: {
                            targetLabel(target)
                        }
                        .accessibilityIdentifier("ssh.addMenu.computer.\(target.name)")
                    }
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

    /// Bare Text/Text/Image tuple: UIMenu reads title, subtitle, then icon
    /// (see WorkspaceMacTitlePicker).
    @ViewBuilder
    private func targetLabel(_ target: WorkspaceCreateComputerTarget) -> some View {
        Text(target.name)
        if let statusText = target.statusText {
            Text(statusText)
        }
        Image(uiImage: Self.statusDot(target.statusColor))
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
