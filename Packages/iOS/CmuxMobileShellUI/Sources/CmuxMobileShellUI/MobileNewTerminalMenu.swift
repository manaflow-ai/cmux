import CmuxMobileSupport
import SwiftUI

/// The "+" toolbar button shared by the workspace list and the disconnected
/// shell. One tap performs ``MobileNewTerminalMenuValue/primaryAction``; a
/// press-and-hold lists every known Mac plus the local Linux terminal on this
/// iPhone, so the user picks where the next terminal opens.
///
/// HIG: Menus (pull-down menu with a primary action) and Toolbars.
struct MobileNewTerminalMenu: View, Equatable {
    let value: MobileNewTerminalMenuValue
    let actions: MobileNewTerminalMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        Menu {
            if value.canCreateWorkspace {
                Button(action: actions.createWorkspace) {
                    Label(
                        L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
                if value.canCreateWorkspaceGroup, let createWorkspaceGroup = actions.createWorkspaceGroup {
                    Button(action: createWorkspaceGroup) {
                        Label(
                            L10n.string("mobile.workspaceGroup.new", defaultValue: "New Workspace Group"),
                            systemImage: "folder.badge.plus"
                        )
                    }
                    .accessibilityIdentifier("MobileNewWorkspaceGroupMenuItem")
                }
            }
            Section(L10n.string("mobile.newTerminal.hostsHeader", defaultValue: "Open a Terminal On")) {
                ForEach(value.hosts) { host in
                    Button {
                        actions.openTerminal(host)
                    } label: {
                        menuRow(
                            title: host.name,
                            subtitle: Self.statusText(host.status),
                            systemImage: "desktopcomputer"
                        )
                    }
                    .accessibilityIdentifier(Self.hostAccessibilityIdentifier(host.id))
                }
                Button(action: actions.openLocalLinux) {
                    menuRow(
                        title: L10n.string("mobile.newTerminal.localLinux", defaultValue: "Linux on This iPhone"),
                        subtitle: L10n.string(
                            "mobile.newTerminal.localLinux.subtitle",
                            defaultValue: "Alpine Linux, no Mac needed"
                        ),
                        systemImage: "iphone"
                    )
                }
                .disabled(!value.isLocalLinuxAvailable)
                .accessibilityIdentifier("MobileNewTerminalLocalLinuxMenuItem")
            }
            if value.canAddComputer, let addComputer = actions.addComputer {
                Divider()
                Button(action: addComputer) {
                    Label(
                        L10n.string("mobile.connections.add", defaultValue: "Add Computer"),
                        systemImage: "desktopcomputer.and.iphone"
                    )
                }
                .accessibilityIdentifier("MobileNewTerminalAddComputerMenuItem")
            }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            performPrimaryAction()
        }
        .disabled(!value.isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    private func performPrimaryAction() {
        switch value.primaryAction {
        case .createWorkspace:
            actions.createWorkspace()
        case .openLocalLinux:
            actions.openLocalLinux()
        case .addComputer:
            actions.addComputer?()
        case .none:
            break
        }
    }

    private var accessibilityLabel: String {
        switch value.primaryAction {
        case .createWorkspace:
            L10n.string("mobile.workspace.new", defaultValue: "New Workspace")
        case .openLocalLinux, .addComputer, .none:
            L10n.string("mobile.newTerminal.button", defaultValue: "New Terminal")
        }
    }

    /// Menu rows must stay a bare Text/Text/Image tuple: UIMenu bridging reads
    /// the first Text as the title, the second as the subtitle, and the Image
    /// as the item icon. Wrapping them in a stack drops the subtitle entirely.
    @ViewBuilder
    private func menuRow(title: String, subtitle: String, systemImage: String) -> some View {
        Text(title)
        Text(subtitle)
        Image(systemName: systemImage)
    }

    static func statusText(_ status: MobileNewTerminalMenuValue.Host.Status) -> String {
        switch status {
        case .connected:
            L10n.string("mobile.deviceTree.connected", defaultValue: "Connected")
        case .online:
            L10n.string("mobile.deviceTree.online", defaultValue: "Online")
        case .offline:
            L10n.string("mobile.newTerminal.host.offline", defaultValue: "Offline")
        }
    }

    static func hostAccessibilityIdentifier(_ id: String) -> String {
        let stableID = id.replacingOccurrences(of: "\u{1F}", with: "-")
        return "MobileNewTerminalHostMenuItem-\(stableID)"
    }
}
