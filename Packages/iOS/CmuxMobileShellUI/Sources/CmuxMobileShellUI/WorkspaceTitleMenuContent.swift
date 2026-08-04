import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenuContent: View {
    let value: WorkspaceTitleMenuContentValue
    let actions: WorkspaceTitleMenuActions

    var body: some View {
        if value.canCustomizeWorkspace
            || value.canRenameWorkspace
            || value.canToggleReadState
            || value.canCloseWorkspace {
            Section(value.workspaceName) {
                if value.canCustomizeWorkspace {
                    Button(action: actions.presentCustomization) {
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

                if value.canRenameWorkspace
                    && (!value.canCustomizeWorkspace || value.showsRenameAlongsideCustomization) {
                    Button(action: actions.presentRename) {
                        Label(
                            L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace"),
                            systemImage: "pencil"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleRenameMenuItem")
                }

                if value.canToggleReadState {
                    Button(action: actions.toggleReadState) {
                        Label(
                            value.hasUnread
                                ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
                                : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread"),
                            systemImage: value.hasUnread ? "envelope.open" : "envelope.badge"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleReadStateMenuItem")
                }

                if value.canCloseWorkspace {
                    Button(role: .destructive, action: actions.requestClose) {
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
