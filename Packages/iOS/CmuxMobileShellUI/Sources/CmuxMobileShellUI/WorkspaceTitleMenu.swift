import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasChatToggle: Bool
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            menuContent()
        } label: {
            label()
                .frame(
                    minWidth: MobileNavTitleWidth.floor,
                    maxWidth: MobileNavTitleWidth(
                        contentWidth: contentWidth,
                        hasBackButton: hasBackButton,
                        hasChatToggle: hasChatToggle
                    ).leadingCap,
                    alignment: .leading
                )
                .layoutPriority(1)
        }
        .mobileGlassCompactToolbarControl()
        .accessibilityIdentifier("MobileWorkspaceTitleMenu")
    }
}

struct WorkspaceTitleMenuContent: View {
    let workspace: MobileWorkspacePreview
    let canCloseWorkspace: Bool
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let requestClose: () -> Void

    var body: some View {
        if workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || canCloseWorkspace {
            Section(workspace.name) {
                if workspace.actionCapabilities.supportsWorkspaceActions {
                    Button(action: presentRename) {
                        Label(
                            L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace"),
                            systemImage: "pencil"
                        )
                    }
                    .accessibilityIdentifier("MobileWorkspaceTitleRenameMenuItem")
                }

                if workspace.actionCapabilities.supportsReadStateActions {
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
