import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenuContent: View {
    let workspace: MobileWorkspacePreview
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let workspaceChangesAreAvailable: Bool
    let canCloseWorkspace: Bool
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let openWorkspaceChanges: () -> Void
    let requestClose: () -> Void

    var body: some View {
        if canRenameWorkspace
            || canToggleReadState
            || workspaceChangesAreAvailable
            || canCloseWorkspace
        {
            Section(workspace.name) {
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
                            workspace.hasUnread
                                ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
                                : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread"),
                            systemImage: workspace.hasUnread ? "envelope.open" : "envelope.badge"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleReadStateMenuItem")
                }

                if workspaceChangesAreAvailable {
                    Button(action: openWorkspaceChanges) {
                        Label(
                            String(
                                localized: "workspace.changes.title",
                                defaultValue: "Changes",
                                bundle: .module
                            ),
                            systemImage: "plus.forwardslash.minus"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleChangesMenuItem")
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
