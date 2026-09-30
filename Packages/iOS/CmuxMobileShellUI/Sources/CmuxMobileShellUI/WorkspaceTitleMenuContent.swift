import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenuContent: View {
    let workspaceName: String
    let hasUnread: Bool
    let canCustomizeWorkspace: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let canReconnect: Bool
    var canBrowseFiles = false
    let presentCustomization: () -> Void
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let requestClose: () -> Void
    let reconnect: () -> Void
    var browseFiles: () -> Void = {}

    var body: some View {
        if canReconnect {
            Section {
                Button(action: reconnect) {
                    Label(
                        L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceTitleReconnectMenuItem")
            }
        }
        if canBrowseFiles {
            Section {
                Button(action: browseFiles) {
                    Label(
                        L10n.string("mobile.ssh.files.menuItem", defaultValue: "Browse Files"),
                        systemImage: "folder"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceTitleFilesMenuItem")
            }
        }
        if canCustomizeWorkspace || canRenameWorkspace || canToggleReadState || canCloseWorkspace {
            Section(workspaceName) {
                if canCustomizeWorkspace {
                    Button(action: presentCustomization) {
                        Label(
                            L10n.string(
                                "mobile.workspace.customize.title",
                                defaultValue: "Customize Workspace"
                            ),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleCustomizeMenuItem")
                }

                if canRenameWorkspace {
                    Button(action: presentRename) {
                        Label(
                            L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace"),
                            systemImage: "pencil"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleRenameMenuItem")
                }

                if canToggleReadState {
                    Button(action: toggleReadState) {
                        Label(
                            hasUnread
                                ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
                                : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread"),
                            systemImage: hasUnread ? "envelope.open" : "envelope.badge"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleReadStateMenuItem")
                }

                if canCloseWorkspace {
                    Button(role: .destructive, action: requestClose) {
                        Label(
                            L10n.string("mobile.workspace.close.action", defaultValue: "Close Workspace"),
                            systemImage: "xmark.square"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleCloseMenuItem")
                }
            }
        }
    }
}
