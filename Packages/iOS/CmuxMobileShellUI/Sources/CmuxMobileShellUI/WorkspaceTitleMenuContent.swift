import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenuContent: View {
    let workspace: MobileWorkspacePreview
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let showsViewAsText: Bool
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let requestClose: () -> Void
    let createWorkspace: () -> Void
    let openBrowser: () -> Void
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void

    var body: some View {
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

        Section {
            Button(action: createWorkspace) {
                Label(
                    L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                    systemImage: "plus.square.on.square"
                )
            }
            .disabled(!canCreateWorkspace)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button(action: openBrowser) {
                Label(
                    L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                    systemImage: hasActiveBrowser ? "checkmark.circle.fill" : "globe"
                )
            }
            .accessibilityIdentifier("MobileNewBrowserMenuItem")
        }

        #if canImport(UIKit)
        Section {
            if showsViewAsText {
                Button(action: openTextSheet) {
                    Label(
                        L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                        systemImage: "doc.plaintext"
                    )
                }
                .accessibilityIdentifier("MobileViewAsTextMenuItem")
            }

            #if DEBUG
            Button(action: copyDebugLogs) {
                Label(
                    L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                    systemImage: "doc.on.clipboard"
                )
            }
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
            #endif

            Button(action: sendFeedback) {
                Label(
                    L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                    systemImage: "paperplane"
                )
            }
            .accessibilityIdentifier("MobileSendFeedbackMenuItem")
        }
        #endif
    }
}
