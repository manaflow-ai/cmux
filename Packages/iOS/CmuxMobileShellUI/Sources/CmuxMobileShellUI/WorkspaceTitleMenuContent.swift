import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenuContent: View {
    let workspace: MobileWorkspacePreview
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let requestClose: () -> Void
    var openTextSheet: (() -> Void)? = nil
    var copyDebugLogs: (() -> Void)? = nil
    var sendFeedback: (() -> Void)? = nil

    var body: some View {
        if openTextSheet != nil || copyDebugLogs != nil || sendFeedback != nil {
            Section(L10n.string("mobile.workspaceTitleMenu.currentTab", defaultValue: "Current Tab")) {
                if let openTextSheet {
                    Button(action: openTextSheet) {
                        Label(
                            L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                            systemImage: "doc.plaintext"
                        )
                    }
                    .accessibilityIdentifier("MobileViewAsTextMenuItem")
                }

                if let copyDebugLogs {
                    Button(action: copyDebugLogs) {
                        Label(
                            L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                            systemImage: "doc.on.clipboard"
                        )
                    }
                    .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
                }

                if let sendFeedback {
                    Button(action: sendFeedback) {
                        Label(
                            L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                            systemImage: "paperplane"
                        )
                    }
                    .accessibilityIdentifier("MobileSendFeedbackMenuItem")
                }
            }
        }

        if canRenameWorkspace || canToggleReadState || canCloseWorkspace {
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
