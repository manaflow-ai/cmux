import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenuContent: View {
    let workspace: MobileWorkspacePreview
    let canCustomizeWorkspace: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let presentCustomization: () -> Void
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let requestClose: () -> Void

    var body: some View {
        if canCustomizeWorkspace || canRenameWorkspace || canToggleReadState || canCloseWorkspace {
            Section(workspace.name) {
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
                } else if canRenameWorkspace {
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
                            workspace.hasUnread
                                ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
                                : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread"),
                            systemImage: workspace.hasUnread ? "envelope.open" : "envelope.badge"
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
